#!/usr/bin/env bash
# agentbox - per-workspace openshell sandboxes for AI coding agents
# Invoked as `agentbox` for management, or via symlinks (claude, codex, opencode) to launch an agent inside the workspace sandbox.

set -euo pipefail

# Embedded version. Bump when cutting a release; tag the commit as v<version>.
AGENTBOX_VERSION="0.4.15"

AGB_ROOT="${AGB_ROOT:-$HOME/.local/share/agentbox}"
AGB_ORIGINALS="$AGB_ROOT/originals.conf"
AGB_STATE_ROOT="$AGB_ROOT/state"
SSH_CONFIG="$HOME/.ssh/config"
DEFAULT_IMAGE="${AGB_DEFAULT_IMAGE:-base}"
DEFAULT_CPU="${AGB_DEFAULT_CPU:-1}"
DEFAULT_MEMORY="${AGB_DEFAULT_MEMORY:-1Gi}"
MUTAGEN_SYNC_TIMEOUT="${AGB_SYNC_TIMEOUT:-120}"
WORKSPACE_POLICY_FILE=".agentbox.policy.yaml"

log()  { printf '\033[36magentbox:\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33magentbox:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31magentbox:\033[0m %s\n' "$*" >&2; exit 1; }

# Accept any of: 1, true, yes, on (case-insensitive). Anything else = false.
is_truthy() {
  local v
  v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$v" in 1|true|yes|on|y|t) return 0 ;; *) return 1 ;; esac
}

real_binary() {
  awk -F= -v a="$1" '$1==a {print $2; exit}' "$AGB_ORIGINALS" 2>/dev/null
}

inside_sandbox() {
  [ -d /sandbox ] && [ -f /etc/openshell-sandbox ] 2>/dev/null
}

workspace_sandbox_name() {
  local abs base hash
  abs=$(cd "$PWD" && pwd -P)
  base=$(basename "$abs" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+|-+$//g; s/-+/-/g')
  [ -z "$base" ] && base="ws"
  hash=$(printf '%s' "$abs" | shasum -a 256 | cut -c1-8)
  printf 'agentbox-%s-%s' "$base" "$hash"
}

_strip_ansi() {
  awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); print }'
}

sandbox_phase() {
  openshell sandbox list 2>/dev/null \
    | _strip_ansi \
    | awk -v n="$1" 'NR>1 && $1==n {print $NF}'
}

sandbox_ensure() {
  local name="$1" image="$2" cpu="$3" memory="$4" policy="$5"
  local phase
  phase=$(sandbox_phase "$name")

  if [ "$phase" = "Ready" ]; then
    return 0
  fi
  if [ -n "$phase" ]; then
    warn "sandbox $name in phase '$phase' (likely out-of-band container loss) — auto-recovering"
    openshell sandbox delete "$name" >/dev/null 2>&1 || true
    mutagen sync terminate "$name" >/dev/null 2>&1 || true
    mutagen sync terminate "${name}-state" >/dev/null 2>&1 || true
    log "recreating $name from scratch (workspace + persisted state will be restored from host)"
  else
    log "creating sandbox $name (image=$image cpu=$cpu mem=$memory)"
  fi

  local args=( sandbox create --name "$name" --from "$image" --cpu "$cpu" --memory "$memory" --upload ".:/sandbox/work" --no-tty )
  [ -n "$policy" ] && args+=( --policy "$policy" )
  args+=( -- /bin/true )
  openshell "${args[@]}" >/dev/null
}

ssh_host_for() {
  openshell sandbox ssh-config "$1" 2>/dev/null | awk '/^Host / {print $2; exit}'
}

ssh_config_sync() {
  local name="$1"
  local start_marker="# agentbox:start $name"
  local end_marker="# agentbox:end $name"
  local block
  block=$(openshell sandbox ssh-config "$name")

  mkdir -p "$(dirname "$SSH_CONFIG")"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG" 2>/dev/null || true

  awk -v s="$start_marker" -v e="$end_marker" '
    $0 == s { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$SSH_CONFIG" > "$SSH_CONFIG.agbtmp"
  mv "$SSH_CONFIG.agbtmp" "$SSH_CONFIG"

  {
    printf '\n%s\n%s\n%s\n' "$start_marker" "$block" "$end_marker"
  } >> "$SSH_CONFIG"
}

mutagen_session_status() {
  mutagen sync list "$1" 2>/dev/null | awk -F': +' '/^Status/ {print $2; exit}'
}

mutagen_ensure() {
  local name="$1" local_path="$2"
  local status
  status=$(mutagen_session_status "$name" || true)

  if [ -n "$status" ]; then
    mutagen sync flush "$name" >/dev/null 2>&1 || true
    return 0
  fi

  local ssh_host
  ssh_host=$(ssh_host_for "$name")
  [ -z "$ssh_host" ] && err "could not resolve SSH host for sandbox $name (openshell sandbox ssh-config returned nothing)"

  log "starting mutagen sync $name (host:$local_path <-> ${ssh_host}:/sandbox/work)"
  mutagen sync create \
    --name "$name" \
    --mode two-way-resolved \
    --ignore-vcs \
    --ignore '/node_modules' \
    --ignore '/__pycache__' \
    --ignore '/.venv' \
    --ignore '/venv' \
    --ignore '/target' \
    --ignore '/dist' \
    --ignore '/build' \
    --ignore '/.next' \
    --ignore '/.cache' \
    "$local_path" "${ssh_host}:/sandbox/work" >/dev/null

  log "waiting for initial sync (up to ${MUTAGEN_SYNC_TIMEOUT}s)..."
  local i
  for i in $(seq 1 "$MUTAGEN_SYNC_TIMEOUT"); do
    status=$(mutagen_session_status "$name" || true)
    case "$status" in
      Watching*|Idle*) return 0 ;;
    esac
    sleep 1
  done
  warn "mutagen session $name not Ready after ${MUTAGEN_SYNC_TIMEOUT}s (status: ${status:-unknown})"
}

mutagen_state_ensure() {
  # Persists /sandbox/.claude/projects across destroy/recreate so `claude --continue`
  # survives sandbox loss. State lives in $AGB_STATE_ROOT/<sandbox-name>/ on host.
  local name="$1"
  local session_name="${name}-state"
  local host_state="$AGB_STATE_ROOT/$name"
  local status

  mkdir -p "$host_state"
  status=$(mutagen_session_status "$session_name" || true)
  if [ -n "$status" ]; then
    mutagen sync flush "$session_name" >/dev/null 2>&1 || true
    return 0
  fi

  local ssh_host
  ssh_host=$(ssh_host_for "$name")
  [ -z "$ssh_host" ] && { warn "could not resolve SSH host for state sync"; return 0; }

  log "starting state sync $session_name (host:$host_state <-> ${ssh_host}:/sandbox/.claude/projects)"
  mutagen sync create \
    --name "$session_name" \
    --mode two-way-resolved \
    "$host_state" "${ssh_host}:/sandbox/.claude/projects" >/dev/null 2>&1 || \
    warn "state sync failed to start (session history won't persist this run)"
}

# ---- Approval watcher (macOS) ----
# Two orthogonal approval paths coexist:
#   1. Watcher (this section): tails openshell logs and reacts AFTER a deny.
#      Always on (macOS), independent of openshell version. The agent has
#      already seen the 403 by the time the user clicks Allow, so retry is
#      required.
#   2. Decide-server (below cmd_watch_internal): host-side HTTP endpoint
#      that openshell's Interactive enforcement mode (forthcoming, see
#      vshalpnjabi/OpenShell `interactive-enforcement` branch) consults
#      BEFORE denying. First attempt succeeds on Allow; no retry. Gated
#      behind AGENTBOX_DECIDE_SERVER=1 since upstream support is pending.
# Background process that tails openshell logs for NET:OPEN DENIED events and
# prompts the user (osascript display dialog) on the first occurrence of each
# (binary, host:port) tuple. Approval adds the endpoint to the workspace policy
# (hot-reloaded); decisions are remembered per-sandbox so the user is not
# prompted again for the same tuple.

watcher_state_dir() { echo "$AGB_STATE_ROOT/$1"; }
watcher_pid_file()  { echo "$(watcher_state_dir "$1")/watcher.pid"; }
watcher_log_file()  { echo "$(watcher_state_dir "$1")/watcher.log"; }
watcher_seen_file() { echo "$(watcher_state_dir "$1")/watcher-seen.txt"; }
audit_log_file()    { echo "$(watcher_state_dir "$1")/audit.log"; }

# Watcher → decide-server bridge: POST a watcher-origin decision request
# to the local decide-server (running on 127.0.0.1, deterministic port).
# Echoes the response JSON on stdout, or empty on failure. Exits non-zero
# on failure. Used in default mode (decide-server running, AGENTBOX_NO_DECIDE_SERVER unset).
watcher_call_decide_server() {
  local sandbox="$1" host="$2" port="$3" binary="$4" pid="$5"
  local port_file
  port_file="$AGB_STATE_ROOT/$sandbox/decide-server.port"
  [ -f "$port_file" ] || return 1
  local srv_port
  srv_port=$(cat "$port_file" 2>/dev/null) || return 1
  [ -z "$srv_port" ] && return 1

  command -v jq >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local body
  body=$(jq -nc \
    --arg sb "$sandbox" \
    --arg host "$host" \
    --argjson port "$port" \
    --arg bin "$binary" \
    --argjson pid "$pid" \
    --arg src "watcher" \
    --arg rid "watcher-$(date +%s%N 2>/dev/null || date +%s)" \
    '{schema_version:1, request_id:$rid, sandbox_name:$sb, host:$host, port:$port, binary:$bin, pid:$pid, source:$src}') || return 1

  # Bearer token must match what the decide-server was started with (and
  # what the policy YAML's `secret:` field carries). Without it the
  # server returns 401 and we'd fail-closed. Reading the file on every
  # call is cheap and means a secret rotation takes effect immediately.
  local secret=""
  [ -f "$(decide_server_secret_file "$sandbox")" ] && \
    secret=$(cat "$(decide_server_secret_file "$sandbox")" 2>/dev/null || true)

  # Timeout slightly longer than prompt_approval's internal 300s. If the
  # call fails (server died, network blocked), curl exits non-zero, we
  # return non-zero. Watcher's caller treats failure as a terminal Deny
  # (agent unfrozen, gets the original 403 from openshell — same as if
  # the user had clicked Deny manually).
  if [ -n "$secret" ]; then
    curl -fsS --max-time 360 -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $secret" \
      --data "$body" \
      "http://127.0.0.1:$srv_port/decide" 2>/dev/null
  else
    curl -fsS --max-time 360 -X POST \
      -H "Content-Type: application/json" \
      --data "$body" \
      "http://127.0.0.1:$srv_port/decide" 2>/dev/null
  fi
}

# Look up the LAST decision for a (binary, host, port) tuple across both
# seen-list files. Decide-seen.txt is canonical (where new writes go in
# decide-server mode); watcher-seen.txt is legacy (writes go there in
# AGENTBOX_NO_DECIDE_SERVER=1 mode). Reading both preserves entries
# across mode switches and across the v0.2.0 → v0.2.1+ format upgrade.
# Echoes "" if not seen, else "allow" / "allow_wildcard" / "deny" / "legacy".
get_seen_decision_for_key() {
  local sandbox="$1" key="$2"
  local d=""
  local f
  for f in "$AGB_STATE_ROOT/$sandbox/decide-seen.txt" \
           "$AGB_STATE_ROOT/$sandbox/watcher-seen.txt"; do
    [ -s "$f" ] || continue
    local hit
    hit=$(awk -F '|' -v k="$key" '
      $1"|"$2"|"$3 == k { d = (NF >= 4 ? $4 : "legacy") }
      END { print d }
    ' "$f" 2>/dev/null) || hit=""
    if [ -n "$hit" ]; then
      d="$hit"
      break  # decide-seen.txt wins over watcher-seen.txt
    fi
  done
  echo "$d"
}

# Append a structured audit entry. Format: ISO-8601 timestamp + tag + message.
audit_emit() {
  local sandbox="$1" tag="$2" msg="$3"
  local log_file
  log_file=$(audit_log_file "$sandbox")
  mkdir -p "$(dirname "$log_file")"
  printf '%s [agentbox:%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$msg" >> "$log_file"
}

watcher_running() {
  local pf
  pf=$(watcher_pid_file "$1")
  [ -f "$pf" ] || return 1
  local pid
  pid=$(cat "$pf" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

watcher_ensure() {
  local sandbox="$1"
  if is_truthy "${AGENTBOX_NO_WATCH:-}"; then
    log "watcher disabled (AGENTBOX_NO_WATCH=1)"
    return 0
  fi
  if [ "$(uname)" != "Darwin" ]; then
    log "watcher skipped (non-Darwin: $(uname))"
    return 0
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    log "watcher skipped (osascript not found)"
    return 0
  fi

  local pf
  pf=$(watcher_pid_file "$sandbox")

  # ---- ATOMIC SPAWN GUARD ----
  # Without a lock around the orphan-cleanup + pid-file-check + spawn block
  # below, two concurrent watcher_ensure calls (separate `claude` invocations
  # racing in different shells) can both pass the checks and both spawn.
  # Result: two watchers per sandbox, each reading every deny, each spawning
  # an alerter dialog, focus-thrashing the user's terminal, and racing on
  # `openshell policy update`. mkdir is atomic on POSIX filesystems so the
  # first caller wins the lock; others wait briefly then return (the winning
  # caller has either spawned or detected an already-alive watcher by then).
  local state_dir_early
  state_dir_early=$(watcher_state_dir "$sandbox")
  mkdir -p "$state_dir_early"
  local lock="$state_dir_early/.watcher_ensure.lock"
  local lock_wait=0
  while ! mkdir "$lock" 2>/dev/null; do
    # Lock held — check if owner is alive, otherwise treat as stale.
    local lock_owner
    lock_owner=$(cat "$lock/owner" 2>/dev/null || true)
    if [ -z "$lock_owner" ] || ! kill -0 "$lock_owner" 2>/dev/null; then
      log "watcher_ensure: stale lock from dead pid ${lock_owner:-?}, clearing"
      rm -rf "$lock"
      continue
    fi
    lock_wait=$((lock_wait + 1))
    if [ "$lock_wait" -gt 50 ]; then
      log "watcher_ensure: another spawn (pid $lock_owner) holding lock >5s; bailing"
      return 0
    fi
    sleep 0.1
  done
  echo "$$" > "$lock/owner"
  # Release on any exit path (success, return, error, signal).
  trap 'rm -rf '"$lock"'' RETURN

  # Belt-and-suspenders cleanup: kill any orphaned watchers for THIS sandbox
  # by pgrep pattern. The pid file only tracks the most recently started
  # watcher; if two were spawned via a race (separate `claude` invocations
  # in different shells, or a stop+pkill that missed a child subshell), we
  # end up with concurrent watchers that race on `openshell policy update`
  # — each reads policy version N, pushes N+1 with their addition, and
  # the last write wins (overwriting the others' Allow). This is THE
  # cause of "I clicked Allow but the policy didn't actually update".
  local pattern="agentbox.sh __watch $sandbox"
  local orphans
  # `|| true` is load-bearing: pgrep returns 1 when nothing matches (the
  # CORRECT state when there are no orphans), and with `set -euo pipefail`
  # the failing command substitution would silently exit the whole script.
  orphans=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ' || true)
  if [ -n "$orphans" ]; then
    # Distinguish "the one we already have tracked" from "orphans"
    local tracked=""
    [ -f "$pf" ] && tracked=$(cat "$pf" 2>/dev/null) || true
    local to_kill=""
    for p in $orphans; do
      [ "$p" = "$tracked" ] && continue
      to_kill+=" $p"
    done
    if [ -n "$to_kill" ]; then
      log "killing orphan watcher pid(s) for $sandbox:$to_kill"
      kill $to_kill 2>/dev/null || true
      sleep 0.3
      # If anything survived SIGTERM, escalate
      local stubborn
      stubborn=$(pgrep -f "$pattern" 2>/dev/null | grep -vFx "${tracked:-NONE}" | tr '\n' ' ' || true)
      [ -n "$stubborn" ] && kill -9 $stubborn 2>/dev/null || true
    fi
  fi

  # Now check the pid-file-tracked watcher: alive? then we're done.
  if [ -f "$pf" ]; then
    local existing_pid
    existing_pid=$(cat "$pf" 2>/dev/null)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      log "watcher already running (pid $existing_pid) for $sandbox"
      return 0
    fi
    log "removing stale pid file (pid $existing_pid not alive)"
    rm -f "$pf"
  fi

  local state_dir
  state_dir=$(watcher_state_dir "$sandbox")
  mkdir -p "$state_dir"
  log "starting approval watcher for $sandbox (denials prompt; AGENTBOX_NO_WATCH=1 to disable)"

  # Self-respawn via the hidden __watch subcommand
  nohup "$AGB_ROOT/agentbox.sh" __watch "$sandbox" \
    >"$(watcher_log_file "$sandbox")" 2>&1 &
  local spawn_pid=$!
  disown 2>/dev/null || true
  log "watcher spawn pid=$spawn_pid"
}

watcher_stop() {
  local sandbox="$1"
  # Kill ALL watchers for this sandbox (not just the one in the pid file).
  # The pid file only tracks the most recent watcher; orphans from races
  # would survive a pid-file-only kill and continue to interfere.
  # `|| true` on the pgrep pipelines: pgrep returns 1 when nothing matches,
  # which would silently exit the script under `set -euo pipefail`.
  local pattern="agentbox.sh __watch $sandbox"
  local pids
  pids=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ' || true)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    sleep 0.3
    local stubborn
    stubborn=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ' || true)
    [ -n "$stubborn" ] && kill -9 $stubborn 2>/dev/null || true
  fi
  rm -f "$(watcher_pid_file "$sandbox")"
}

# Freeze the agent process(es) inside the sandbox so the TUI visibly pauses
# while the approval dialog is open. Belt-and-suspenders: SIGSTOP the exact
# offending PID (in case the agent is the one calling out directly) plus any
# top-level agent process by name (for tool-spawned-child denies). Single
# openshell exec round-trip to minimize latency before the freeze takes effect.
freeze_sandbox_agents() {
  local sandbox="$1" pid="$2"
  local cmd="kill -STOP $pid 2>/dev/null; pkill -STOP -x claude 2>/dev/null; pkill -STOP -x codex 2>/dev/null; pkill -STOP -x opencode 2>/dev/null; true"
  # </dev/null is required: without it, openshell exec inherits the while-read
  # pipe as stdin and hangs forever waiting for it to close.
  openshell sandbox exec --name "$sandbox" --no-tty -- /bin/sh -c "$cmd" </dev/null >/dev/null 2>&1 || true
}

unfreeze_sandbox_agents() {
  local sandbox="$1" pid="$2"
  local cmd="kill -CONT $pid 2>/dev/null; pkill -CONT -x claude 2>/dev/null; pkill -CONT -x codex 2>/dev/null; pkill -CONT -x opencode 2>/dev/null; true"
  openshell sandbox exec --name "$sandbox" --no-tty -- /bin/sh -c "$cmd" </dev/null >/dev/null 2>&1 || true
}

AGB_NTFY_TOPIC_FILE="$AGB_ROOT/ntfy-topic"
AGB_NTFY_BASE="${AGB_NTFY_BASE:-https://ntfy.sh}"

# Sanitize a user-supplied ntfy topic. Strips an optional scheme + host
# prefix (so users can paste a full URL like https://ntfy.sh/foo or
# ntfy.sh/foo and get just "foo"), then validates against ntfy's
# acceptable character set. Echoes the cleaned topic on success.
ntfy_sanitize_topic() {
  local raw="$1"
  # Strip leading whitespace + scheme + host so URL pastes work.
  local t="${raw#"${raw%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  t="${t#http://}"
  t="${t#https://}"
  t="${t#ntfy.sh/}"
  case "$t" in
    */*) t="${t##*/}" ;;
  esac
  # ntfy topics: 1-64 chars, alnum + _ + - (we keep the strict subset).
  case "$t" in
    "" )
      return 1 ;;
    *[!A-Za-z0-9_-]* )
      return 1 ;;
  esac
  [ "${#t}" -gt 64 ] && return 1
  printf '%s\n' "$t"
}

# Resolve the active ntfy topic. Priority:
#   1. $AGENTBOX_NTFY_TOPIC env (per-shell override; portable across hosts)
#   2. $AGB_NTFY_TOPIC_FILE   (persisted via `agentbox notify setup`)
ntfy_get_topic() {
  if [ -n "${AGENTBOX_NTFY_TOPIC:-}" ]; then
    ntfy_sanitize_topic "$AGENTBOX_NTFY_TOPIC" && return 0
    return 1
  fi
  [ -f "$AGB_NTFY_TOPIC_FILE" ] || return 1
  local t
  t=$(tr -d "[:space:]" < "$AGB_NTFY_TOPIC_FILE")
  [ -n "$t" ] && printf '%s\n' "$t"
}

# Returns "env" or "file" depending on where ntfy_get_topic resolved from.
# Echoes nothing if no topic is configured.
ntfy_topic_source() {
  if [ -n "${AGENTBOX_NTFY_TOPIC:-}" ] && ntfy_sanitize_topic "$AGENTBOX_NTFY_TOPIC" >/dev/null 2>&1; then
    echo "env"
  elif [ -f "$AGB_NTFY_TOPIC_FILE" ] && [ -s "$AGB_NTFY_TOPIC_FILE" ]; then
    echo "file"
  fi
}

# Locate the user's login-shell rc file. Falls back to ~/.profile if the
# shell is unknown so the env block lands SOMEWHERE sourceable. fish has
# its own syntax, so we report it for the caller to handle differently.
# Echoes "<kind>|<path>"; kind is one of: zsh|bash|fish|profile.
_shell_rc_target() {
  local s="${SHELL:-}"
  case "$s" in
    */zsh)  printf 'zsh|%s\n'  "$HOME/.zshrc" ;;
    */bash) printf 'bash|%s\n' "$HOME/.bashrc" ;;
    */fish) printf 'fish|%s\n' "$HOME/.config/fish/config.fish" ;;
    *)      printf 'profile|%s\n' "$HOME/.profile" ;;
  esac
}

# Idempotently persist (or remove) the agentbox ntfy env block in the user's
# shell rc. The block is delimited by markers so re-running `notify setup
# --global` updates the topic in place instead of duplicating.
# Args:
#   $1 = "set" | "unset"
#   $2 = topic value (only when "set")
# Returns 0 on success, prints the path it wrote to on stderr.
_persist_ntfy_env() {
  local op="$1" topic="${2:-}"
  local target kind rc
  target=$(_shell_rc_target)
  kind="${target%%|*}"
  rc="${target#*|}"
  mkdir -p "$(dirname "$rc")"
  [ -f "$rc" ] || : > "$rc"

  # Strip any existing block (idempotent for both set + unset).
  local tmp
  tmp=$(mktemp -t agentbox-rc-edit.XXXXXX 2>/dev/null) || tmp="/tmp/agentbox-rc-edit-$$"
  awk '
    BEGIN { in_block = 0 }
    /^# >>> agentbox notify/ { in_block = 1; next }
    in_block && /^# <<< agentbox notify/ { in_block = 0; next }
    !in_block { print }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"

  if [ "$op" = "set" ]; then
    {
      printf '\n# >>> agentbox notify (managed by `agentbox notify setup --global`; do not edit by hand)\n'
      case "$kind" in
        fish)
          printf 'set -gx AGENTBOX_NTFY_TOPIC %s\n' "$topic"
          printf 'set -gx AGENTBOX_NTFY 1\n'
          ;;
        *)
          printf 'export AGENTBOX_NTFY_TOPIC=%s\n' "$topic"
          printf 'export AGENTBOX_NTFY=1\n'
          ;;
      esac
      printf '# <<< agentbox notify\n'
    } >> "$rc"
  fi

  echo "$rc"
}

# Derive a wildcard parent zone from a hostname for the "Allow all *.parent" UX:
#   static.rust-lang.org → *.rust-lang.org    (strip leftmost label)
#   crates.io            → *.crates.io        (2-label apex stays prefixed)
#   download.crates.io   → *.crates.io        (strip leftmost label)
#   cdn.s.example.com    → *.s.example.com    (strip leftmost label)
# The wildcard matches subdomains of the parent zone but typically not the
# apex itself (openshell's pattern); that's the desired semantics — apex is
# already in front of you as "host" and approved separately on this prompt.
wildcard_for_host() {
  local h="$1"
  local dots="${h//[^.]/}"
  local count=${#dots}
  if [ "$count" -ge 2 ]; then
    echo "*.${h#*.}"
  else
    echo "*.${h}"
  fi
}

ntfy_prompt() {
  # Send an actionable ntfy notification with three HTTP action buttons that
  # POST back to the same topic. Long-poll the topic for the user's response
  # (filtered by a unique request id). Echos "Allow" / "Deny" /
  # "AllowWildcard:*.parent.host" / "" (timeout).
  local topic="$1" sandbox="$2" host="$3" port="$4" binary="$5"
  local bname; bname=$(basename "$binary")
  local wild; wild=$(wildcard_for_host "$host")
  local req_id; req_id=$(printf '%s%s' "$(date +%s%N 2>/dev/null || date +%s)" "$$" | shasum -a 256 | cut -c1-16)
  local since; since=$(date +%s)
  local url="$AGB_NTFY_BASE/$topic"

  # POST the notification with THREE actions: Allow, Allow all <wildcard>, Deny.
  # ntfy allows up to 3 action buttons per notification.
  curl -fsS -X POST \
    -H "Title: agentbox: approve network access?" \
    -H "Priority: high" \
    -H "Tags: warning,lock" \
    -H "Actions: http, Allow, $url, method=POST, body=ALLOW $req_id; http, Allow all $wild, $url, method=POST, body=WILDCARD $req_id; http, Deny, $url, method=POST, body=DENY $req_id" \
    -d "$bname -> $host:$port (sandbox: $sandbox)" \
    "$url" >/dev/null 2>&1 || { echo ""; return; }

  # Long-poll for response.
  local timeout=300
  local deadline=$(( since + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local result
    result=$(curl -fsS --max-time 10 "$url/json?poll=1&since=${since}s" 2>/dev/null \
      | jq -r --arg id "$req_id" 'select(.message? | strings | test("^(ALLOW|DENY|WILDCARD) " + $id + "$")) | .message' \
      | head -1)
    if [[ "$result" =~ ^ALLOW ]]; then
      echo "Allow"; return
    elif [[ "$result" =~ ^WILDCARD ]]; then
      echo "AllowWildcard:$wild"; return
    elif [[ "$result" =~ ^DENY ]]; then
      echo "Deny"; return
    fi
    sleep 2
  done
  echo ""
}

# Resolve which notification backend prompt_approval would use right now.
# Mirrors prompt_approval's decision tree without actually firing a prompt.
notification_backend() {
  if is_truthy "${AGENTBOX_NTFY:-}" \
      && ntfy_get_topic >/dev/null 2>&1 \
      && command -v curl >/dev/null 2>&1 \
      && command -v jq >/dev/null 2>&1; then
    echo "ntfy.sh (cross-device push)"; return
  fi
  if [ "$(uname)" = "Darwin" ] && command -v alerter >/dev/null 2>&1; then
    echo "alerter (macOS banner)"; return
  fi
  if [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    echo "osascript display alert (macOS modal)"; return
  fi
  if command -v zenity >/dev/null 2>&1; then
    echo "zenity (Linux GUI)"; return
  fi
  if command -v notify-send >/dev/null 2>&1; then
    echo "notify-send + /dev/tty prompt (Linux)"; return
  fi
  if [ -r /dev/tty ]; then
    echo "/dev/tty interactive prompt"; return
  fi
  echo "none (fail-closed: all denies auto-Deny)"
}

# Prompt the user via alerter (proper macOS banner notification with
# Allow/Deny action buttons; sender identity = com.apple.Terminal so the
# notification isn't silently dropped on macOS 15+). Falls back to osascript
# display alert if alerter isn't installed.
# Echos "Allow", "Deny", or "" (timeout / dismissed).
prompt_approval() {
  local sandbox="$1" host="$2" port="$3" binary="$4"
  local title="agentbox: approve network access?"
  local bname; bname=$(basename "$binary")
  local subtitle="${bname} -> ${host}:${port}"
  local wild; wild=$(wildcard_for_host "$host")
  local message="(sandbox: ${sandbox})"
  local wild_label="Allow all $wild"

  # ntfy.sh backend (cross-device push, three-button inline). STRICTLY opt-in:
  # both AGENTBOX_NTFY=1 must be exported AND a topic must be configured via
  # `agentbox notify setup`. Without the env var, alerter is used even if a
  # topic is saved (so the topic file isn't a hidden on-switch).
  if is_truthy "${AGENTBOX_NTFY:-}"; then
    local topic
    if topic=$(ntfy_get_topic) && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      local result
      result=$(ntfy_prompt "$topic" "$sandbox" "$host" "$port" "$binary")
      case "$result" in
        Allow|Deny|AllowWildcard:*)
          echo "$result"
          return 0
          ;;
      esac
      echo "[watcher] ntfy returned no decision; falling back to alerter" >&2
    elif ! topic=$(ntfy_get_topic); then
      echo "[watcher] AGENTBOX_NTFY=1 set but no topic configured (agentbox notify setup)" >&2
    fi
  fi

  # macOS: alerter banner notification is the default. Only TWO actions so
  # macOS doesn't collapse into a "Show" dropdown — "Allow" as the primary
  # button and "Deny" as the close-button label.
  #
  # "Allow" semantically grants the wildcard zone *.parent.host. The
  # AllowWildcard handler ALSO adds the exact host as a separate endpoint
  # in the same policy rule, because openshell wildcards match subdomains
  # only (apex would otherwise silently still be denied). The narrower
  # exact-only grant remains available in the osascript / ntfy / zenity
  # backends.
  if [ "$(uname)" = "Darwin" ] && command -v alerter >/dev/null 2>&1; then
    local response
    response=$(alerter \
      --title "$title" \
      --subtitle "$subtitle" \
      --message "$message" \
      --actions "Allow" \
      --close-label "Deny" \
      --timeout 300 \
      --sound default \
      2>/dev/null)
    case "$response" in
      Allow)              echo "AllowWildcard:$wild" ;;
      Deny|@CLOSED)       echo "Deny" ;;
      *)                  echo "" ;;
    esac
    return 0
  fi

  # macOS fallback: osascript display alert (3-button modal). Fires only
  # when alerter isn't installed.
  if [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    local response
    response=$(osascript 2>/dev/null <<APPLESCRIPT
display alert "${title}" message "${subtitle}
${message}" as informational buttons {"Deny", "${wild_label}", "Allow"} default button "Allow"
APPLESCRIPT
)
    # Order matters: "Allow all *.x" contains "Allow" so the wildcard
    # match must come before the bare-Allow match.
    case "$response" in
      *"Allow all "*) echo "AllowWildcard:$wild" ;;
      *Allow*)        echo "Allow" ;;
      *Deny*)         echo "Deny" ;;
      *)              echo "" ;;
    esac
    return 0
  fi

  # Linux: zenity --list with three rows (Allow / Allow all <wildcard> / Deny).
  # The default --question is binary; --list lets us offer the 3rd option.
  if command -v zenity >/dev/null 2>&1; then
    local choice
    choice=$(zenity --list \
      --title="$title" \
      --text="${subtitle}\n\n${message}\n\nSelect a decision:" \
      --column "Decision" \
      "Allow" \
      "$wild_label" \
      "Deny" \
      --width=480 --height=260 --timeout=300 2>/dev/null) || true
    case "$choice" in
      Allow)         echo "Allow" ;;
      "$wild_label") echo "AllowWildcard:$wild" ;;
      Deny)          echo "Deny" ;;
      *)             echo "" ;;
    esac
    return 0
  fi

  if command -v notify-send >/dev/null 2>&1; then
    notify-send -t 0 "$title" "$subtitle"$'\n'"$message"$'\n\nNo GUI dialog available; answer in the terminal.' 2>/dev/null || true
  fi

  # Last-resort fallback: read from /dev/tty (works on any platform when interactive).
  # Three keys: a=Allow, w=Wildcard, d=Deny.
  #
  # `[ -r /dev/tty ]` passes whenever the device node is readable, but in a
  # daemonised handler subprocess (e.g. spawned by the decide-server) there's
  # no controlling terminal, so the subsequent open() returns ENXIO. Use a
  # subshell with redirection to actually probe open()-ability before reading.
  if { : < /dev/tty; } 2>/dev/null; then
    printf '\n[agentbox] %s\n  %s\n  %s\n  [a]llow / [w]ildcard (%s) / [d]eny: ' \
      "$title" "$subtitle" "$message" "$wild" > /dev/tty
    local ans=""
    read -r ans < /dev/tty || ans=""
    case "$ans" in
      a|A|allow|Allow|y|Y|yes|Yes) echo "Allow" ;;
      w|W|wildcard|Wildcard)       echo "AllowWildcard:$wild" ;;
      *)                            echo "Deny" ;;
    esac
    return 0
  fi

  # No prompt mechanism available: fail-closed (deny). Surface WHY to stderr so
  # operators can fix the gap (most common: AGENTBOX_NTFY=1 not in the env of
  # the process that started the decide-server, so ntfy never fires in handler
  # subprocesses; or running on Linux without ntfy + without a TTY).
  echo "[prompt_approval] no prompt path available — fail-closed Deny" >&2
  echo "[prompt_approval]   uname=$(uname) AGENTBOX_NTFY=${AGENTBOX_NTFY:-unset} topic_file_exists=$([ -f "$AGB_NTFY_TOPIC_FILE" ] && echo yes || echo no) alerter=$(command -v alerter >/dev/null && echo yes || echo no) osascript=$(command -v osascript >/dev/null && echo yes || echo no) zenity=$(command -v zenity >/dev/null && echo yes || echo no) tty_openable=no" >&2
  echo "Deny"
}

# ---- tmux wrap for interactive agent sessions ----
# Each workspace's TTY agent launch is wrapped in a deterministic tmux session
# (default-on; opt out with AGENTBOX_NO_TMUX=1). Two reasons:
#   1. inject_retry_to_agent uses `tmux send-keys -t <session>` which delivers
#      the retry prompt to the agent's pane regardless of which window has
#      focus — fixing the "agent terminal not in focus" gap in the keystroke
#      path.
#   2. Detach/reattach for free: Ctrl-B d to detach, `agentbox attach` to
#      come back. Survives terminal-window close.
# Skipped automatically when already inside an outer tmux ($TMUX set) — nesting
# is messy and we don't know which outer pane holds the agent.

# All agentbox tmux state lives on a private socket (`-L`). This isolates
# sessions, key bindings, hooks, and options from the user's own tmux
# server — so the mouse / copy-mode tweaks below don't leak into their
# regular tmux config. The trade-off: `tmux ls` from a normal shell won't
# show these sessions; use `agentbox attach` or `tmux -L agentbox ls`.
AGB_TMUX_SOCKET="${AGENTBOX_TMUX_SOCKET:-agentbox}"
agb_tmux() { tmux -L "$AGB_TMUX_SOCKET" "$@"; }

# Session name = sandbox name; sandbox names already start with "agentbox-".
tmux_session_for_sandbox() { echo "$1"; }

tmux_available() { command -v tmux >/dev/null 2>&1; }

tmux_have_session() {
  tmux_available || return 1
  agb_tmux has-session -t "$(tmux_session_for_sandbox "$1")" 2>/dev/null
}

# Should we wrap this launch in tmux? Returns 0 (yes) only when all three hold:
#   - AGENTBOX_NO_TMUX isn't truthy
#   - tmux is installed
#   - we're not already inside someone else's tmux (TMUX env)
tmux_should_wrap() {
  is_truthy "${AGENTBOX_NO_TMUX:-}" && return 1
  tmux_available || return 1
  [ -n "${TMUX:-}" ] && return 1
  return 0
}

tmux_kill_session() {
  tmux_available || return 0
  agb_tmux kill-session -t "$(tmux_session_for_sandbox "$1")" 2>/dev/null || true
}

# Apply agentbox's preferred session-level options + server-level mouse
# bindings. Bindings live on tmux key tables (server-global) but since we
# run on a private socket, they don't pollute the user's normal tmux.
# Idempotent — safe to call on every attach.
apply_agentbox_tmux_settings() {
  # All settings here are applied SERVER-GLOBAL (`-g`) on agentbox's private
  # tmux socket — not session-scoped. This means:
  #   1. New sessions inherit them automatically.
  #   2. Reattaches via plain `tmux -L agentbox attach` (bypassing cmd_attach)
  #      still see the right config — no stale session-level overrides.
  #   3. We can also un-set any session-level overrides that may have been
  #      written by older agentbox versions (-u -t session).
  # First-arg session is kept only to clear potential session-level overrides
  # from older installs; the actual settings are server-global.
  local session="${1:-}"
  tmux_available || return 0

  # Clear any session-level overrides from older agentbox versions so the
  # global -g settings below take effect uncontested.
  if [ -n "$session" ]; then
    agb_tmux set-option -u -t "$session" mouse              >/dev/null 2>&1 || true
    agb_tmux set-option -u -t "$session" history-limit      >/dev/null 2>&1 || true
    agb_tmux set-option -u -t "$session" status             >/dev/null 2>&1 || true
    agb_tmux set-option -u -t "$session" status-left        >/dev/null 2>&1 || true
    agb_tmux set-option -u -t "$session" status-left-length >/dev/null 2>&1 || true
  fi

  # Mouse on: scroll wheel scrolls history; click selects pane; etc.
  agb_tmux set-option -g mouse "${AGENTBOX_TMUX_MOUSE:-on}" >/dev/null 2>&1 || true
  # Bigger scrollback than tmux's default of 2000 lines.
  agb_tmux set-option -g history-limit "${AGENTBOX_TMUX_HISTORY:-10000}" >/dev/null 2>&1 || true
  # Status-left: agentbox-branded label + workspace name (with the redundant
  # leading "agentbox-" prefix stripped via tmux #{s/.../.../:var} format
  # substitution). The `^` anchor is load-bearing — tmux's substitution is
  # global by default, so without `^` the middle "agentbox-" would also get
  # stripped in agentbox-on-agentbox workspaces, leaving just the bare hash.
  if is_truthy "${AGENTBOX_TMUX_STATUS_OFF:-}"; then
    agb_tmux set-option -g status off >/dev/null 2>&1 || true
  else
    agb_tmux set-option -g status on >/dev/null 2>&1 || true
    # The default value can't be inlined as `${VAR:-default}` because
    # bash's parameter-expansion default-value parser eats the closing
    # `}` of #{s/.../.../:session_name} thinking it's the closing brace
    # of ${...}. Build the default in a separate variable instead.
    local status_left_default=' #[fg=cyan,bold]agentbox#[fg=default,nobold]:#[fg=green]#{s/^agentbox-//:session_name}#[default] #[fg=cyan]| '
    local status_left="${AGENTBOX_TMUX_STATUS_LEFT:-$status_left_default}"
    agb_tmux set-option -g status-left "$status_left" >/dev/null 2>&1 || true
    agb_tmux set-option -g status-left-length \
      "${AGENTBOX_TMUX_STATUS_LEFT_LENGTH:-80}" >/dev/null 2>&1 || true
  fi
  # Make copy-mode less sticky: any mouse click (no drag) immediately
  # cancels and returns to live input.
  agb_tmux bind-key -T copy-mode    MouseDown1Pane send-keys -X cancel >/dev/null 2>&1 || true
  agb_tmux bind-key -T copy-mode-vi MouseDown1Pane send-keys -X cancel >/dev/null 2>&1 || true

  # Disable tmux click-and-drag selection. The default `MouseDrag1Pane`
  # binding (root table) runs `copy-mode -M` the instant any motion is
  # detected while button 1 is pressed. On terminals with sensitive mouse
  # reporting (notably Ghostty), this fires on essentially every click,
  # entering copy-mode and continuing the selection as the mouse moves
  # — the user perceives this as "random highlighting on mouse move."
  # Removing the binding means scroll-wheel still works (WheelUp/Down)
  # but click+drag no longer captures selection through tmux. If the
  # user wants native-terminal selection back, set AGENTBOX_TMUX_DRAG_SELECT=1.
  if ! is_truthy "${AGENTBOX_TMUX_DRAG_SELECT:-}"; then
    agb_tmux unbind-key -T root         MouseDrag1Pane    >/dev/null 2>&1 || true
    agb_tmux unbind-key -T copy-mode    MouseDrag1Pane    >/dev/null 2>&1 || true
    agb_tmux unbind-key -T copy-mode-vi MouseDrag1Pane    >/dev/null 2>&1 || true
    agb_tmux unbind-key -T copy-mode    MouseDragEnd1Pane >/dev/null 2>&1 || true
    agb_tmux unbind-key -T copy-mode-vi MouseDragEnd1Pane >/dev/null 2>&1 || true
  fi
}

# Type a retry prompt into the agent's TUI. Preferred delivery path is
# `tmux send-keys` (focus-independent, exact pane targeting). Falls back to
# OS-level keystroke injection into the frontmost window for users who opted
# out of the tmux wrap (or whose system lacks tmux):
#   macOS  — osascript via System Events (Accessibility permission required).
#   Linux  — xdotool type (X11 only; Wayland has no equivalent).
#   other  — print the prompt and let the user paste it manually.
#
# Keystroke caveat: types into whatever has focus. A brief sleep lets the
# alerter dialog finish dismissing so focus returns to the terminal, but if
# the user switched apps, the keystroke goes elsewhere. The tmux path doesn't
# have this fragility.
inject_retry_to_agent() {
  local sandbox="$1" host="$2" port="$3" binary="$4"
  local prompt
  # Default kept short ("retry") so the char-by-char typing finishes fast
  # and there's less surface area for paste-detect heuristics to trigger.
  # Override with a longer / more detailed instruction via AGENTBOX_RETRY_PROMPT.
  prompt="${AGENTBOX_RETRY_PROMPT:-retry}"

  # Preferred path: tmux send-keys to the agent's wrapped session. No focus
  # dependency, no keystroke fragility, works on macOS/Linux/Wayland/Windows.
  if tmux_have_session "$sandbox"; then
    local session
    session=$(tmux_session_for_sandbox "$sandbox")
    # AGENTBOX_RETRY_DELAY is the focus-settle wait for the keystroke
    # fallback (osascript/xdotool need active focus on the terminal
    # after the alerter dismisses). For tmux send-keys it's pure
    # latency — skip unless explicitly set.
    if [ -n "${AGENTBOX_RETRY_DELAY:-}" ]; then
      sleep "$AGENTBOX_RETRY_DELAY"
    fi

    # Type char-by-char with a small per-char delay so the agent's TUI
    # doesn't detect a paste burst. Claude Code (and similar Ink-based
    # TUIs) switch to multi-line input mode when many chars arrive in a
    # single read(), after which NO Enter combination submits — paste
    # mode "swallows" subsequent newlines into the input. Pacing the
    # injection like human typing avoids this entirely.
    # Default per-char delay 0.02s → ~2s for a 100-char prompt.
    local typing_delay="${AGENTBOX_RETRY_TYPING_DELAY:-0.02}"
    echo "[watcher] typing retry prompt into $session ($(printf '%s' "$prompt" | wc -c | tr -d ' ') chars)" >&2
    local i len=${#prompt}
    local typed_ok=1
    for ((i=0; i<len; i++)); do
      if ! agb_tmux send-keys -t "$session" -l -- "${prompt:$i:1}" 2>/dev/null; then
        typed_ok=0; break
      fi
      [ "$typing_delay" != "0" ] && sleep "$typing_delay"
    done

    if [ "$typed_ok" -eq 1 ]; then
      sleep "${AGENTBOX_RETRY_SUBMIT_DELAY:-0.15}"
      # Configurable submit-key sequence. Default Enter — works once
      # char-by-char typing has kept us out of paste-detect mode.
      # If the agent still doesn't submit, override:
      #   AGENTBOX_RETRY_SUBMIT_KEY="Escape Enter"  # vim-style
      #   AGENTBOX_RETRY_SUBMIT_KEY="C-Enter"       # Ctrl+Enter
      #   AGENTBOX_RETRY_SUBMIT_KEY="M-Enter"       # Alt+Enter
      #   AGENTBOX_RETRY_SUBMIT_KEY="none"          # don't submit;
      #                                             # user presses Enter
      local submit_spec="${AGENTBOX_RETRY_SUBMIT_KEY:-Enter}"
      if [ "$submit_spec" != "none" ]; then
        local k
        for k in $submit_spec; do
          agb_tmux send-keys -t "$session" "$k" 2>/dev/null || true
          sleep 0.05
        done
      fi
      audit_emit "$sandbox" "retry" "INJECTED (tmux, typed) $binary -> $host:$port"
      echo "[watcher] retry injected via tmux send-keys (session: $session, submit=$submit_spec)" >&2
      return 0
    fi
    echo "[watcher] tmux send-keys failed; falling back to OS keystroke" >&2
  fi

  case "$(uname)" in
    Darwin)
      if ! command -v osascript >/dev/null 2>&1; then
        echo "[watcher] osascript missing; cannot auto-inject retry — paste this:" >&2
        echo "  $prompt" >&2
        return 0
      fi
      # Brief settle delay for window focus to return to the terminal after
      # the alerter notification dismisses. Tunable via AGENTBOX_RETRY_DELAY.
      sleep "${AGENTBOX_RETRY_DELAY:-1}"
      # Escape backslashes and double-quotes for the AppleScript string literal.
      local esc
      esc=$(printf '%s' "$prompt" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      # Type the prompt, then press Return (key code 36). System Events sends
      # the keystrokes to the frontmost application.
      if osascript \
          -e "tell application \"System Events\" to keystroke \"$esc\"" \
          -e 'tell application "System Events" to key code 36' \
          2>/dev/null; then
        audit_emit "$sandbox" "retry" "INJECTED (osascript) $binary -> $host:$port"
        echo "[watcher] retry injected via keystroke (frontmost window)" >&2
      else
        echo "[watcher] retry injection failed (Accessibility permission?) — paste manually:" >&2
        echo "  $prompt" >&2
        audit_emit "$sandbox" "retry" "INJECT_FAILED (osascript) $binary -> $host:$port"
      fi
      ;;
    Linux)
      if command -v xdotool >/dev/null 2>&1; then
        sleep "${AGENTBOX_RETRY_DELAY:-1}"
        if xdotool type --delay 10 -- "$prompt" 2>/dev/null && \
           xdotool key Return 2>/dev/null; then
          audit_emit "$sandbox" "retry" "INJECTED (xdotool) $binary -> $host:$port"
          echo "[watcher] retry injected via xdotool (X11 frontmost window)" >&2
        else
          echo "[watcher] xdotool failed (Wayland? not focused?) — paste manually:" >&2
          echo "  $prompt" >&2
          audit_emit "$sandbox" "retry" "INJECT_FAILED (xdotool) $binary -> $host:$port"
        fi
      else
        echo "[watcher] xdotool not installed; copy/paste:" >&2
        echo "  $prompt" >&2
        audit_emit "$sandbox" "retry" "INJECT_SKIPPED (no xdotool) $binary -> $host:$port"
      fi
      ;;
    *)
      echo "[watcher] retry injection not supported on $(uname); copy/paste:" >&2
      echo "  $prompt" >&2
      audit_emit "$sandbox" "retry" "INJECT_SKIPPED ($(uname)) $binary -> $host:$port"
      ;;
  esac
}

# The actual watcher loop, run in the background. Invoked as `agentbox __watch <sandbox>`.
cmd_watch_internal() {
  local sandbox="${1:-}"
  [ -z "$sandbox" ] && { echo "usage: agentbox __watch <sandbox>" >&2; exit 2; }
  local state_dir pid_file seen_file
  state_dir=$(watcher_state_dir "$sandbox")
  pid_file="$state_dir/watcher.pid"
  seen_file="$state_dir/watcher-seen.txt"
  mkdir -p "$state_dir"
  touch "$seen_file"
  echo "$$" > "$pid_file"
  trap 'rm -f "$pid_file"' EXIT TERM INT

  echo "[watcher] starting for $sandbox at $(date)" >&2

  # Outer loop: reconnect if openshell logs disconnects (sandbox restart, etc.)
  while true; do
    # Verify sandbox still exists; exit cleanly if not.
    if ! openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$sandbox"; then
      echo "[watcher] sandbox $sandbox no longer exists; exiting" >&2
      exit 0
    fi

    openshell logs "$sandbox" --tail --since 1s 2>/dev/null | while IFS= read -r line; do
      # Persist every line to the host-side audit log (openshell's in-memory
      # ring buffer is bounded and lost on gateway restart).
      printf '%s\n' "$line" >> "$(audit_log_file "$sandbox")"
      [[ "$line" =~ NET:OPEN.*DENIED ]] || continue
      # Match: <binary>(<pid>) -> <host>:<port>
      if [[ "$line" =~ ([/A-Za-z0-9._-]+)\(([0-9]+)\)[[:space:]]*-\>[[:space:]]*([A-Za-z0-9.-]+):([0-9]+) ]]; then
        local binary="${BASH_REMATCH[1]}"
        local pid="${BASH_REMATCH[2]}"
        local host="${BASH_REMATCH[3]}"
        local port="${BASH_REMATCH[4]}"
        local key="${binary}|${host}|${port}"

        # Seen-list gates re-prompting by the LAST decision for this tuple
        # across BOTH seen-list files (decide-seen.txt + watcher-seen.txt).
        # See get_seen_decision_for_key for rules.
        #   allow / allow_wildcard → suppress (you've already said yes)
        #   deny                   → re-prompt (lets you change your mind,
        #                             catches openshell hot-reload misses)
        #   legacy (pre-v0.2.1)    → re-prompt once; the new decision will
        #                             be stored with the format suffix
        #   not in list            → prompt fresh
        # AGENTBOX_SUPPRESS_REPEATS=1 suppresses everything (v0.1.0 behavior).
        local seen_decision
        seen_decision=$(get_seen_decision_for_key "$sandbox" "$key")
        case "$seen_decision" in
          allow|allow_wildcard)
            echo "[watcher] suppressed (previously $seen_decision): $key" >&2
            continue
            ;;
          deny|legacy)
            if is_truthy "${AGENTBOX_SUPPRESS_REPEATS:-}"; then
              echo "[watcher] suppressed (previous $seen_decision; AGENTBOX_SUPPRESS_REPEATS=1): $key" >&2
              continue
            fi
            echo "[watcher] re-prompting (previous: $seen_decision): $key" >&2
            ;;
        esac

        echo "[watcher] denied: $binary($pid) -> $host:$port — freezing" >&2
        freeze_sandbox_agents "$sandbox" "$pid"

        # Two modes from here:
        # (a) Default — decide-server is running. Route the decision
        #     through it (single source of truth for prompts + policy
        #     updates + seen-list writes). Watcher just handles SIGSTOP/
        #     SIGCONT and the optional retry-inject. If the decide-server
        #     call itself fails, the watcher treats it as a terminal
        #     Deny — agent is unfrozen and gets the original 403.
        # (b) AGENTBOX_NO_DECIDE_SERVER=1 — legacy v0.2.0+ direct-prompt
        #     path. Watcher calls prompt_approval, applies policy update,
        #     writes watcher-seen.txt.
        local decision="deny"
        local effective_host="$host"
        local kind=""

        if ! is_truthy "${AGENTBOX_NO_DECIDE_SERVER:-}" && decide_server_running "$sandbox"; then
          # ----- (a) L7 path -----
          echo "[watcher] routing decision through decide-server (source=watcher)" >&2
          local resp_json
          resp_json=$(watcher_call_decide_server "$sandbox" "$host" "$port" "$binary" "$pid" 2>/dev/null) || resp_json=""
          if [ -n "$resp_json" ]; then
            decision=$(printf '%s' "$resp_json" | jq -r '.decision // "deny"' 2>/dev/null) || decision="deny"
            kind=$(printf '%s' "$resp_json" | jq -r '.kind // ""' 2>/dev/null) || kind=""
            local eh
            eh=$(printf '%s' "$resp_json" | jq -r '.effective_host // ""' 2>/dev/null) || eh=""
            [ -n "$eh" ] && effective_host="$eh"
            audit_emit "$sandbox" "decision" "[via decide-server] ${decision} $binary -> ${effective_host}:$port (kind=${kind:-n/a})"
            echo "[watcher] decide-server: $decision (effective_host=$effective_host, kind=$kind)" >&2
          else
            decision="deny"
            audit_emit "$sandbox" "decision" "DECIDE_SERVER_FAIL $binary -> $host:$port (treating as Deny)"
            echo "[watcher] decide-server call failed; treating as Deny" >&2
          fi
          # NOTE: decide-server already updated openshell policy + wrote
          # decide-seen.txt. Watcher must NOT do those again.

        else
          # ----- (b) Legacy direct prompt path -----
          [ "${AGENTBOX_NO_DECIDE_SERVER:-}" ] && echo "[watcher] using direct prompt path (AGENTBOX_NO_DECIDE_SERVER=1)" >&2 \
                                              || echo "[watcher] decide-server not running; using direct prompt path" >&2
          local response
          response=$(prompt_approval "$sandbox" "$host" "$port" "$binary")
          echo "[watcher] user response: [$response]" >&2
          local seen_decision_value="deny"
          if [[ "$response" == AllowWildcard:* ]]; then
            effective_host="${response#AllowWildcard:}"
            kind="wildcard"
            decision="allow"
            seen_decision_value="allow_wildcard"
          elif [[ "$response" == *"Allow"* ]]; then
            kind="exact"
            decision="allow"
            seen_decision_value="allow"
          fi
          if [ "$decision" = "allow" ]; then
            if openshell policy update "$sandbox" \
                --add-endpoint "${effective_host}:${port}" \
                --binary "$binary" \
                --wait >/dev/null 2>&1; then
              audit_emit "$sandbox" "decision" "ALLOW $binary -> ${effective_host}:$port (kind=$kind; policy hot-reloaded + persisted)"
              echo "[watcher] approved ($kind): $effective_host:$port" >&2
              printf '%s|%s\n' "$key" "$seen_decision_value" >> "$seen_file"
              auto_policy_append "$effective_host" "$port" "$binary"
            else
              echo "[watcher] openshell policy update returned non-zero — treating as Deny" >&2
              audit_emit "$sandbox" "decision" "ALLOW_FAIL $binary -> ${effective_host}:$port (kind=$kind; policy update failed)"
              decision="deny"
            fi
          else
            audit_emit "$sandbox" "decision" "DENY $binary -> $host:$port (user declined)"
            echo "[watcher] denied by user: $host:$port" >&2
            printf '%s|deny\n' "$key" >> "$seen_file"
          fi
        fi

        # Always unfreeze BEFORE retry-inject. Chars typed into a SIGSTOPped
        # agent's pty buffer up and arrive in a burst on SIGCONT — the exact
        # paste-detect trigger char-by-char typing exists to avoid.
        unfreeze_sandbox_agents "$sandbox" "$pid"
        echo "[watcher] unfroze agents in $sandbox" >&2

        # Retry-inject only on allow + AGENTBOX_FORCE_RETRY. If neither,
        # show a passive notification (legacy v0.2.0 behavior).
        if [ "$decision" = "allow" ]; then
          if is_truthy "${AGENTBOX_FORCE_RETRY:-}"; then
            inject_retry_to_agent "$sandbox" "$host" "$port" "$binary"
          else
            osascript -e "display notification \"${effective_host}:${port} allowed.\" with title \"agentbox\"" 2>/dev/null || true
          fi
        fi
      fi
    done

    # Reconnect after brief pause
    sleep 2
  done
}

# ---- Decide-server (host-side HTTP endpoint for openshell Interactive mode) ----
# Spec: github.com/vshalpnjabi/OpenShell `interactive-enforcement` branch,
# docs/interactive-enforcement/DESIGN.md.
#
# Lifecycle is per-sandbox (mirrors the watcher): one HTTP server, deterministic
# port from sandbox-name hash, pid/port/log files in the watcher state dir.
# Currently opt-in via AGENTBOX_DECIDE_SERVER=1 — defaults off until openshell
# Interactive mode actually exists upstream.

decide_server_pid_file()    { echo "$(watcher_state_dir "$1")/decide-server.pid"; }
decide_server_port_file()   { echo "$(watcher_state_dir "$1")/decide-server.port"; }
decide_server_log_file()    { echo "$(watcher_state_dir "$1")/decide-server.log"; }
decide_server_seen_file()   { echo "$(watcher_state_dir "$1")/decide-seen.txt"; }
decide_server_secret_file() { echo "$(watcher_state_dir "$1")/decide-secret.txt"; }

# Per-sandbox shared bearer token for openshell ↔ decide-server auth.
# Created once on first call, persisted at decide-secret.txt (mode 600).
# Both the policy YAML (`secret:` field on each interactive endpoint)
# and the python decide-server (`--secret-file` arg) read the same file —
# single source of truth. The L4 watcher's own POSTs include it too so
# the server can't tell them apart from openshell's, but it can reject
# any other origin.
ensure_decide_secret() {
  local sandbox="$1"
  local f
  f=$(decide_server_secret_file "$sandbox")
  if [ -s "$f" ]; then
    cat "$f"
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  local secret
  if command -v openssl >/dev/null 2>&1; then
    secret=$(openssl rand -hex 32)
  elif command -v xxd >/dev/null 2>&1; then
    secret=$(head -c 32 /dev/urandom | xxd -p -c 64)
  else
    secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  printf '%s\n' "$secret" > "$f"
  chmod 600 "$f"
  printf '%s' "$secret"
}

# Resolve the directory of agentbox.sh, following symlinks (portable across
# macOS where readlink(1) lacks -f). $AGB_ROOT/agentbox.sh is a symlink into
# this repo, so the python script lives alongside the resolved target.
_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  (cd -P "$(dirname "$src")" && pwd)
}

decide_server_python_script() {
  echo "$(_resolve_script_dir)/bin/agentbox-decide.py"
}

# Map sandbox name → deterministic port in [49152, 65535] (IANA dynamic range).
decide_server_port_for_sandbox() {
  local h
  h=$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)
  echo $((16#$h % 16384 + 49152))
}

decide_server_running() {
  local pf
  pf=$(decide_server_pid_file "$1")
  [ -f "$pf" ] || return 1
  local pid
  pid=$(cat "$pf" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

decide_server_ensure() {
  local sandbox="$1"
  # Default-on. Opt out with AGENTBOX_NO_DECIDE_SERVER=1 for users who want
  # the v0.2.0 pure-watcher behavior (no localhost HTTP hop in the prompt
  # path). Legacy AGENTBOX_DECIDE_SERVER=1 is still honored as a no-op
  # signal of intent — useful for grepping configs to see who relied on it.
  if is_truthy "${AGENTBOX_NO_DECIDE_SERVER:-}"; then
    return 0
  fi

  local py
  py=$(decide_server_python_script)
  if [ ! -f "$py" ]; then
    warn "decide-server script not found at $py; skipping"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not on PATH; decide-server skipped (install python3 or set AGENTBOX_NO_DECIDE_SERVER=1)"
    return 0
  fi

  local pf port_file log_file
  pf=$(decide_server_pid_file "$sandbox")
  port_file=$(decide_server_port_file "$sandbox")
  log_file=$(decide_server_log_file "$sandbox")
  mkdir -p "$(dirname "$pf")"

  local port
  port=$(decide_server_port_for_sandbox "$sandbox")

  if [ -f "$pf" ]; then
    local existing_pid
    existing_pid=$(cat "$pf" 2>/dev/null)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      # Verify the process is actually responsive, not just alive. Earlier we
      # saw the single-threaded HTTPServer get wedged (process alive, port
      # listening, but connections time out). The threaded server should
      # make this rare, but a defensive health-probe is cheap insurance.
      local bind_probe="${AGENTBOX_DECIDE_BIND:-127.0.0.1}"
      [ "$bind_probe" = "0.0.0.0" ] && bind_probe="127.0.0.1"
      if command -v curl >/dev/null 2>&1 && \
         curl -fsS -m 2 "http://${bind_probe}:${port}/health" >/dev/null 2>&1; then
        log "decide-server already running (pid $existing_pid) for $sandbox"
        return 0
      fi
      warn "decide-server pid $existing_pid is alive but unresponsive — restarting"
      kill "$existing_pid" 2>/dev/null
      sleep 1
      kill -9 "$existing_pid" 2>/dev/null
    else
      log "removing stale decide-server pid file (pid $existing_pid not alive)"
    fi
    rm -f "$pf"
  fi

  # Handler invokes agentbox.sh's __decide subcommand. The python server runs
  # this via /bin/sh -c, so we hand it a single shell-quoted command line.
  local self_path="${BASH_SOURCE[0]}"
  local handler
  handler=$(printf '%q __decide %q' "$self_path" "$sandbox")

  # Bind address. Default 127.0.0.1 (CLAUDE.md rule 10 — safe; no HMAC auth
  # exists yet). Override with AGENTBOX_DECIDE_BIND when the openshell proxy
  # runs inside a container and reaches agentbox via host.openshell.internal,
  # which resolves to the docker-bridge IP (typically 10.x or 192.168.x).
  # Setting 0.0.0.0 makes the endpoint visible to any process on the host —
  # only do this on trusted networks until the auth story is settled.
  local bind="${AGENTBOX_DECIDE_BIND:-127.0.0.1}"

  # Ensure the per-sandbox shared secret exists; same file is referenced
  # from the policy YAML's `secret:` field so the openshell gateway and the
  # decide-server agree on the bearer token.
  ensure_decide_secret "$sandbox" >/dev/null
  local secret_file
  secret_file=$(decide_server_secret_file "$sandbox")

  log "starting decide-server for $sandbox on ${bind}:${port}"
  nohup python3 "$py" \
    --port "$port" \
    --bind "$bind" \
    --sandbox "$sandbox" \
    --handler "$handler" \
    --pid-file "$pf" \
    --secret-file "$secret_file" \
    >"$log_file" 2>&1 &
  disown 2>/dev/null || true

  printf '%s\n' "$port" > "$port_file"
}

decide_server_stop() {
  local sandbox="$1"
  local pf
  pf=$(decide_server_pid_file "$sandbox")
  if [ -f "$pf" ]; then
    local pid
    pid=$(cat "$pf" 2>/dev/null)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      # If the process has a stuck request and ignores SIGTERM, escalate.
      local i
      for i in 1 2 3 4; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
  rm -f "$(decide_server_port_file "$sandbox")"
}

# Per-request handler. Reads request JSON on stdin (see DESIGN.md wire protocol),
# returns response JSON on stdout. Invoked once per /decide call by the python
# server subprocess. Cached decisions live in decide-seen.txt with KEY|DECISION
# format, separate from the watcher's seen-list since the decide path needs to
# remember the *direction* of the prior decision (allow vs deny).
cmd_decide_handler_internal() {
  local sandbox="${1:-${AGENTBOX_DECIDE_SANDBOX:-}}"
  if [ -z "$sandbox" ]; then
    printf '{"decision":"deny","reason":"no sandbox in handler invocation"}\n'
    return 0
  fi
  local state_dir seen_file
  state_dir=$(watcher_state_dir "$sandbox")
  seen_file=$(decide_server_seen_file "$sandbox")
  mkdir -p "$state_dir"
  touch "$seen_file"

  local body
  body=$(cat)
  # Parse the full openshell interactive-enforcement wire protocol
  # (docs/openshell-interactive-enforcement.md). Fields the openshell proxy
  # sends today: host, port, binary, request_id, schema_version, sandbox_name,
  # pid, method, path, protocol, policy_name. Earlier watcher-internal calls
  # only set host/port/binary/request_id/source — those keep working since the
  # extra fields default to empty.
  local host port binary req_id source schema_version body_sandbox pid method req_path protocol policy_name
  host=$(printf '%s' "$body"           | jq -r '.host // empty'           2>/dev/null || echo "")
  port=$(printf '%s' "$body"           | jq -r '.port // empty'           2>/dev/null || echo "")
  binary=$(printf '%s' "$body"         | jq -r '.binary // empty'         2>/dev/null || echo "")
  req_id=$(printf '%s' "$body"         | jq -r '.request_id // empty'     2>/dev/null || echo "")
  schema_version=$(printf '%s' "$body" | jq -r '.schema_version // empty' 2>/dev/null || echo "")
  body_sandbox=$(printf '%s' "$body"   | jq -r '.sandbox_name // empty'   2>/dev/null || echo "")
  pid=$(printf '%s' "$body"            | jq -r '.pid // empty'            2>/dev/null || echo "")
  method=$(printf '%s' "$body"         | jq -r '.method // empty'         2>/dev/null || echo "")
  req_path=$(printf '%s' "$body"       | jq -r '.path // empty'           2>/dev/null || echo "")
  protocol=$(printf '%s' "$body"       | jq -r '.protocol // empty'       2>/dev/null || echo "")
  policy_name=$(printf '%s' "$body"    | jq -r '.policy_name // empty'    2>/dev/null || echo "")
  # `source` distinguishes who called us:
  #   openshell  (default) — L7 Interactive enforcement (when upstream lands)
  #   watcher              — L4 deny caught by agentbox's log-tail watcher
  # Used for audit log clarity. Behavior is the same either way.
  source=$(printf '%s' "$body" | jq -r '.source // empty' 2>/dev/null || echo "")
  [ -z "$source" ] && source="openshell"

  # Reject schema versions we don't understand — but accept missing/empty
  # (legacy watcher callers don't set it).
  if [ -n "$schema_version" ] && [ "$schema_version" != "1" ]; then
    audit_emit "$sandbox" "decide" "BAD_SCHEMA [src=$source] ${req_id:-?}: schema_version=$schema_version (expected 1)"
    printf '{"decision":"deny","reason":"unsupported schema_version %s"}\n' "$schema_version"
    return 0
  fi

  # If the request body names a sandbox, it MUST match the one this server
  # was bound to at startup. This guards against the openshell proxy
  # accidentally routing a decision request to the wrong agentbox instance.
  if [ -n "$body_sandbox" ] && [ "$body_sandbox" != "$sandbox" ]; then
    audit_emit "$sandbox" "decide" "WRONG_SANDBOX [src=$source] ${req_id:-?}: body=$body_sandbox server=$sandbox"
    printf '{"decision":"deny","reason":"sandbox_name mismatch (body=%s server=%s)"}\n' "$body_sandbox" "$sandbox"
    return 0
  fi

  if [ -z "$host" ] || [ -z "$port" ] || [ -z "$binary" ]; then
    audit_emit "$sandbox" "decide" "BAD_REQUEST [src=$source] ${req_id:-?}: host='$host' port='$port' binary='$binary'"
    printf '{"decision":"deny","reason":"missing host/port/binary"}\n'
    return 0
  fi

  local key="${binary}|${host}|${port}"
  local cached=""
  # Decision cache, gated by previous decision direction:
  #   allow / allow_wildcard → always return cached (user said yes)
  #   deny                   → re-prompt by default; cached only if
  #                            AGENTBOX_SUPPRESS_REPEATS=1
  if [ -s "$seen_file" ]; then
    cached=$(awk -F '|' -v k="$key" '$1"|"$2"|"$3 == k {d=$4} END{print d}' "$seen_file" 2>/dev/null || echo "")
  fi
  case "$cached" in
    allow|allow_wildcard)
      audit_emit "$sandbox" "decide" "CACHED_ALLOW [src=$source] ${req_id:-?}: $binary -> $host:$port"
      printf '{"decision":"allow","reason":"cached","kind":"%s"}\n' "$cached"
      return 0
      ;;
    deny)
      if is_truthy "${AGENTBOX_SUPPRESS_REPEATS:-}"; then
        audit_emit "$sandbox" "decide" "CACHED_DENY [src=$source] ${req_id:-?}: $binary -> $host:$port"
        printf '{"decision":"deny","reason":"cached"}\n'
        return 0
      fi
      # Fall through to re-prompt
      ;;
  esac

  # Build a context suffix from any new spec fields the proxy supplied so the
  # audit log shows what the agent was actually trying to do (helps when
  # reviewing past decisions).
  local ctx=""
  [ -n "$method" ]      && ctx="${ctx} ${method}"
  [ -n "$req_path" ]    && ctx="${ctx} ${req_path}"
  [ -n "$protocol" ] && [ "$protocol" != "unknown" ] && ctx="${ctx} (proto=$protocol)"
  [ -n "$policy_name" ] && ctx="${ctx} (policy=$policy_name)"
  [ -n "$pid" ]         && ctx="${ctx} (pid=$pid)"
  audit_emit "$sandbox" "decide" "PROMPT [src=$source] ${req_id:-?}: $binary ->${ctx} $host:$port"
  local response
  response=$(prompt_approval "$sandbox" "$host" "$port" "$binary")

  # Helper to emit a JSON response with optional kind/effective_host fields.
  # Uses jq for safe escaping (especially of wildcard hosts in the future).
  _decide_reply() {
    # _decide_reply <decision> <reason> [kind] [effective_host]
    jq -nc \
      --arg d "$1" --arg r "$2" \
      --arg kind "${3:-}" --arg eh "${4:-}" \
      '{decision:$d, reason:$r}
       + (if $kind != "" then {kind:$kind} else {} end)
       + (if $eh   != "" then {effective_host:$eh} else {} end)'
  }

  case "$response" in
    Allow)
      # Three modes:
      #
      #   AGENTBOX_SYNC_POLICY_UPDATE=1
      #     Full blocking wait. Pre-v0.4.13 behavior. Agent waits ~7s
      #     on stock 0.0.42 for the supervisor to confirm policy active.
      #     Strongest correctness: agent's next retry succeeds first try.
      #
      #   AGENTBOX_POLICY_UPDATE_TIMEOUT=0
      #     Pure async. Reply "allow" instantly; policy update runs in
      #     background. v0.4.13 behavior. Agent may retry several times
      #     before policy is active (watcher silently re-unfreezes via
      #     the now-cached seen=allow each time).
      #
      #   AGENTBOX_POLICY_UPDATE_TIMEOUT=N (default 3)
      #     Bounded wait. Start the update in background, wait up to N
      #     seconds for it to complete. If it finishes within N, the
      #     agent's first retry succeeds. If not, reply anyway and let
      #     the update finish in background. Common case (~7s on stock)
      #     waits 3s, then 1-2 background retries before success.
      #
      # The seen-list commit + auto_policy_append happen SYNCHRONOUSLY
      # in every mode so a subsequent deny gets seen=allow lookup.
      printf '%s|allow\n' "$key" >> "$seen_file"
      auto_policy_append "$host" "$port" "$binary"
      if is_truthy "${AGENTBOX_SYNC_POLICY_UPDATE:-}"; then
        echo "[decide] applying policy update for ${host}:${port} (sync mode, ~5-10s on stock)" >&2
        local _t0=$(date +%s)
        if openshell policy update "$sandbox" \
            --add-endpoint "${host}:${port}" \
            --binary "$binary" \
            --wait >/dev/null 2>&1; then
          echo "[decide] policy active after $(( $(date +%s) - _t0 ))s" >&2
          audit_emit "$sandbox" "decide" "USER_ALLOW [src=$source] ${req_id:-?}: $binary -> $host:$port (sync; $(( $(date +%s) - _t0 ))s)"
        else
          audit_emit "$sandbox" "decide" "USER_ALLOW_FAIL [src=$source] ${req_id:-?}: $binary -> $host:$port (sync; openshell policy update returned non-zero)"
        fi
      else
        local _timeout="${AGENTBOX_POLICY_UPDATE_TIMEOUT:-3}"
        audit_emit "$sandbox" "decide" "USER_ALLOW [src=$source] ${req_id:-?}: $binary -> $host:$port (bg policy update; max wait ${_timeout}s)"
        # Launch update in background (always — so timeout doesn't kill it)
        (
          _t0=$(date +%s)
          if openshell policy update "$sandbox" \
              --add-endpoint "${host}:${port}" \
              --binary "$binary" \
              --wait >/dev/null 2>&1; then
            audit_emit "$sandbox" "decide" "BG_POLICY_ACTIVE [src=$source] ${req_id:-?}: $binary -> $host:$port ($(( $(date +%s) - _t0 ))s)"
          else
            audit_emit "$sandbox" "decide" "BG_POLICY_FAIL [src=$source] ${req_id:-?}: $binary -> $host:$port ($(( $(date +%s) - _t0 ))s)"
          fi
        ) </dev/null >/dev/null 2>&1 &
        local _bg_pid=$!
        disown 2>/dev/null || true
        # Bounded wait: poll up to $_timeout seconds for the bg to finish.
        # Granularity is 100ms — fine enough to feel snappy, coarse enough
        # to not burn CPU. macOS sleep accepts fractional seconds.
        if [ "$_timeout" -gt 0 ]; then
          local _budget_ms=$(( _timeout * 1000 ))
          local _elapsed_ms=0
          while [ "$_elapsed_ms" -lt "$_budget_ms" ] && kill -0 "$_bg_pid" 2>/dev/null; do
            sleep 0.1
            _elapsed_ms=$(( _elapsed_ms + 100 ))
          done
        fi
      fi
      _decide_reply "allow" "user approved" "exact" "$host"
      ;;
    AllowWildcard:*)
      # User picked "Allow all *.parent.host" (or clicked Allow on the 2-action
      # alerter, which maps to this path). Add BOTH the wildcard zone AND the
      # exact apex host to the policy — openshell wildcards match subdomains
      # only, so granting just *.github.com would leave the apex denied.
      #
      # Same backgrounding strategy as the Allow case: commit to the seen-list
      # immediately, reply "allow" to the watcher so the agent unfreezes, and
      # let the two policy updates finish in parallel in the background.
      local wild="${response#AllowWildcard:}"
      printf '%s|allow_wildcard\n' "$key" >> "$seen_file"
      auto_policy_append "$wild" "$port" "$binary"
      auto_policy_append "$host" "$port" "$binary"
      if is_truthy "${AGENTBOX_SYNC_POLICY_UPDATE:-}"; then
        local ok_w=0 ok_h=0
        openshell policy update "$sandbox" \
          --add-endpoint "${wild}:${port}" \
          --binary "$binary" \
          --wait >/dev/null 2>&1 && ok_w=1
        openshell policy update "$sandbox" \
          --add-endpoint "${host}:${port}" \
          --binary "$binary" \
          --wait >/dev/null 2>&1 && ok_h=1
        audit_emit "$sandbox" "decide" "USER_ALLOW_WILDCARD [src=$source] ${req_id:-?}: $binary -> {$wild,$host}:$port (sync; wildcard_ok=$ok_w apex_ok=$ok_h)"
      else
        local _timeout="${AGENTBOX_POLICY_UPDATE_TIMEOUT:-3}"
        audit_emit "$sandbox" "decide" "USER_ALLOW_WILDCARD [src=$source] ${req_id:-?}: $binary -> {$wild,$host}:$port (bg policy update; max wait ${_timeout}s)"
        (
          _t0=$(date +%s)
          # Parallel: both at once, ~7s instead of ~14s.
          openshell policy update "$sandbox" \
            --add-endpoint "${wild}:${port}" \
            --binary "$binary" \
            --wait >/dev/null 2>&1 &
          _pid_w=$!
          openshell policy update "$sandbox" \
            --add-endpoint "${host}:${port}" \
            --binary "$binary" \
            --wait >/dev/null 2>&1 &
          _pid_h=$!
          ok_w=0; wait "$_pid_w" && ok_w=1
          ok_h=0; wait "$_pid_h" && ok_h=1
          if [ "$ok_w" = "1" ] || [ "$ok_h" = "1" ]; then
            audit_emit "$sandbox" "decide" "BG_POLICY_ACTIVE [src=$source] ${req_id:-?}: $binary -> {$wild,$host}:$port (wildcard_ok=$ok_w apex_ok=$ok_h, $(( $(date +%s) - _t0 ))s)"
          else
            audit_emit "$sandbox" "decide" "BG_POLICY_FAIL [src=$source] ${req_id:-?}: $binary -> {$wild,$host}:$port (both updates failed, $(( $(date +%s) - _t0 ))s)"
          fi
        ) </dev/null >/dev/null 2>&1 &
        local _bg_pid=$!
        disown 2>/dev/null || true
        if [ "$_timeout" -gt 0 ]; then
          local _budget_ms=$(( _timeout * 1000 ))
          local _elapsed_ms=0
          while [ "$_elapsed_ms" -lt "$_budget_ms" ] && kill -0 "$_bg_pid" 2>/dev/null; do
            sleep 0.1
            _elapsed_ms=$(( _elapsed_ms + 100 ))
          done
        fi
      fi
      _decide_reply "allow" "user approved wildcard $wild + apex $host" "wildcard" "$wild"
      ;;
    Deny)
      printf '%s|deny\n' "$key" >> "$seen_file"
      audit_emit "$sandbox" "decide" "USER_DENY [src=$source] ${req_id:-?}: $binary -> $host:$port"
      _decide_reply "deny" "user denied"
      ;;
    *)
      # Timeout / no UI: deny but don't cache, so the next attempt re-prompts.
      audit_emit "$sandbox" "decide" "TIMEOUT [src=$source] ${req_id:-?}: $binary -> $host:$port (fail-closed)"
      _decide_reply "deny" "prompt timed out"
      ;;
  esac
  return 0
}

load_config() {
  AGB_IMAGE="$DEFAULT_IMAGE"
  AGB_CPU="$DEFAULT_CPU"
  AGB_MEMORY="$DEFAULT_MEMORY"
  AGB_POLICY=""
  AGB_UPLOAD_CREDS="false"
  AGB_SUDO="false"
  [ ! -f .agentbox.toml ] && return 0
  while IFS='=' read -r key val; do
    key=$(printf '%s' "$key" | tr -d ' ')
    val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
    case "$key" in
      image) AGB_IMAGE="$val" ;;
      cpu) AGB_CPU="$val" ;;
      memory) AGB_MEMORY="$val" ;;
      policy) AGB_POLICY="$val" ;;
      upload_credentials) AGB_UPLOAD_CREDS="$val" ;;
      sudo) AGB_SUDO="$val" ;;
    esac
  done < .agentbox.toml
}

# Find the Docker container ID backing an openshell sandbox. Openshell
# names its containers including the sandbox name; we filter docker ps.
# Returns the ID on stdout (one line) or non-zero exit if not found.
find_sandbox_container() {
  local sandbox="$1"
  command -v docker >/dev/null 2>&1 || return 1
  local cid
  # Strategy 1: container name contains the sandbox name
  cid=$(docker ps --filter "name=$sandbox" --format '{{.ID}}' 2>/dev/null | head -1)
  if [ -n "$cid" ]; then printf '%s\n' "$cid"; return 0; fi
  # Strategy 2: openshell may set a sandbox label
  cid=$(docker ps --filter "label=openshell.sandbox=$sandbox" --format '{{.ID}}' 2>/dev/null | head -1)
  if [ -n "$cid" ]; then printf '%s\n' "$cid"; return 0; fi
  return 1
}

# Grant the sandbox user NOPASSWD sudo so the agent can run privileged
# operations (apt install, systemctl, edit /etc/*) inside its own sandbox.
# Stays fully contained — sudo here cannot reach the host. Opt-in via
# AGENTBOX_SUDO=1 env or `sudo = true` in .agentbox.toml. Default off.
#
# openshell sandbox exec has no --user flag, so we go straight to
# `docker exec -u 0 <container>` against the underlying Docker container.
# Docker Desktop on macOS doesn't require host sudo for this; openshell's
# gRPC gateway runs Docker on our behalf as the same user.
setup_sandbox_sudo() {
  local sandbox="$1"

  # Idempotent: short-circuit if NOPASSWD sudo already works.
  if openshell sandbox exec --name "$sandbox" --no-tty -- sudo -n true \
       </dev/null >/dev/null 2>&1; then
    return 0
  fi

  log "configuring NOPASSWD sudo inside $sandbox (opt-in via AGENTBOX_SUDO)"

  # Single-line script (kept for parity even though docker exec doesn't
  # enforce the same newline restriction openshell does). Tries to install
  # sudo via the container's package manager if missing. apt-get / apk /
  # dnf / yum supported. Requires network access from inside the container
  # for the apt repos — openshell's network policy may block this; if so
  # we fall through to a clear error.
  local setup_script
  setup_script='set -e; if ! command -v sudo >/dev/null 2>&1; then echo "agentbox-sudo: sudo not in image, attempting install..." >&2; if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null 2>&1 || { echo "agentbox-sudo: apt-get install sudo failed (network blocked by openshell policy?)" >&2; exit 1; }; elif command -v apk >/dev/null 2>&1; then apk add --no-cache sudo >/dev/null 2>&1 || { echo "agentbox-sudo: apk add sudo failed" >&2; exit 1; }; elif command -v dnf >/dev/null 2>&1; then dnf install -y -q sudo >/dev/null 2>&1 || { echo "agentbox-sudo: dnf install sudo failed" >&2; exit 1; }; elif command -v yum >/dev/null 2>&1; then yum install -y -q sudo >/dev/null 2>&1 || { echo "agentbox-sudo: yum install sudo failed" >&2; exit 1; }; else echo "agentbox-sudo: no known package manager (apt/apk/dnf/yum)" >&2; exit 1; fi; fi; USER_NAME=$(stat -c "%U" /sandbox 2>/dev/null || stat -f "%Su" /sandbox 2>/dev/null || echo sandbox); mkdir -p /etc/sudoers.d; printf "%s ALL=(ALL) NOPASSWD: ALL\n" "$USER_NAME" > /etc/sudoers.d/agentbox; chmod 0440 /etc/sudoers.d/agentbox; echo "agentbox-sudo: NOPASSWD configured for user $USER_NAME"'

  local container
  if ! container=$(find_sandbox_container "$sandbox"); then
    warn "could not find Docker container for sandbox '$sandbox'"
    warn "  Try: docker ps | grep $sandbox"
    return 1
  fi

  if docker exec -u 0 "$container" /bin/sh -c "$setup_script"; then
    audit_emit "$sandbox" "sudo" "NOPASSWD sudo enabled (via docker exec -u 0)"
    log "  ✓ sudo ready inside $sandbox"
    return 0
  fi

  warn "docker exec -u 0 failed (see output above)"
  warn "manual workaround:"
  warn "  container=\$(docker ps --filter name=$sandbox --format '{{.ID}}' | head -1)"
  warn "  docker exec -u 0 \$container /bin/sh -c 'USER_NAME=\$(stat -c \"%U\" /sandbox); printf \"%s ALL=(ALL) NOPASSWD: ALL\\\\n\" \"\$USER_NAME\" > /etc/sudoers.d/agentbox && chmod 0440 /etc/sudoers.d/agentbox'"
  return 1
}

write_default_policy() {
  local target="$1"
  cat > "$target" <<'YAML'
# agentbox auto-generated sandbox policy
# Default: deny-all network, baseline filesystem (workspace at /sandbox/work + system paths).
# Edit this file to grant additional access. Static fields (filesystem/landlock/process)
# require `agentbox destroy && claude` to take effect; network_policies hot-reloads on
# `openshell policy update <sandbox>` against a running sandbox.
#
# Reference: https://docs.nvidia.com/openshell/reference/default-policy
# Schema:    https://docs.nvidia.com/openshell/reference/policy-schema
version: 1

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

filesystem_policy:
  # Full sandbox filesystem access — agents can read+write anywhere inside the
  # container that the sandbox user (uid:gid sandbox:sandbox) has permission to
  # access. The container itself is still the security boundary; this just
  # disables the additional Landlock LSM constraints inside it.
  #
  # openshell rejects a single "/" entry as "overly broad", so we enumerate
  # the standard Linux roots. Combined this covers every path the sandbox can
  # touch. Trim back to a stricter set per-workspace if you want defense-in-depth.
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /lib64
    - /bin
    - /sbin
    - /opt
    - /proc
    - /sys
    - /etc
  read_write:
    - /sandbox
    - /tmp
    - /var
    - /run
    - /home
    - /root
    - /dev

# Each network_policies entry has: name, endpoints (list of {host, port[, protocol, access, ...]}), binaries.
# Endpoint defaults to TCP passthrough; add protocol: rest + access: <preset> for L7 inspection.
# Hot-reload changes here with `agentbox policy reload`.
#
# Defaults: agents allowed to reach their APIs + GitHub open to git/curl/agents.
# Add/remove blocks to taste; `agentbox policy reload` hot-applies network changes.
network_policies:
  claude_code:
    name: claude-code
    endpoints:
      - { host: api.anthropic.com, port: 443 }
      - { host: platform.claude.com, port: 443 }
      - { host: claude.ai, port: 443 }
      - { host: downloads.claude.ai, port: 443 }
      - { host: statsig.anthropic.com, port: 443 }
      - { host: mcp-proxy.anthropic.com, port: 443 }
      - { host: http-intake.logs.us5.datadoghq.com, port: 443 }
    binaries:
      - { path: /usr/local/bin/claude }

  codex:
    name: codex
    endpoints:
      - { host: api.openai.com, port: 443 }
      - { host: chatgpt.com, port: 443 }
      - { host: auth.openai.com, port: 443 }
    binaries:
      - { path: /usr/bin/codex }

  opencode:
    name: opencode
    endpoints:
      - { host: opencode.ai, port: 443 }
      - { host: api.opencode.ai, port: 443 }
    binaries:
      - { path: /usr/bin/opencode }

  github:
    name: github
    endpoints:
      - { host: github.com, port: 443 }
      - { host: api.github.com, port: 443 }
      - { host: raw.githubusercontent.com, port: 443 }
      - { host: objects.githubusercontent.com, port: 443 }
      - { host: codeload.github.com, port: 443 }
      - { host: gist.github.com, port: 443 }
      - { host: ghcr.io, port: 443 }
    binaries:
      - { path: /usr/local/bin/claude }
      - { path: /usr/bin/codex }
      - { path: /usr/bin/opencode }
      - { path: /usr/bin/git }
      - { path: /usr/bin/curl }
      - { path: /usr/bin/wget }
      - { path: /usr/bin/ssh }
YAML

  # Opt-IN interactive-enforcement block. Appended only when
  # AGENTBOX_INTERACTIVE_POLICY=1 is set AND we can determine the sandbox's
  # decide-server port. When the openshell `interactive-enforcement` fork
  # is built + running on the host, this rule lets ANY denied host be
  # approved on the fly via the alerter/ntfy prompt — without an L4 reject
  # + retry roundtrip. See: docs/openshell-interactive-enforcement.md
  #
  # NOTE: stock openshell (NVIDIA 0.0.42 and earlier) does NOT silently
  # downgrade the `enforcement: { mode, ... }` map — it FAILS the YAML
  # parse with `invalid type: map, expected a string`, which makes the
  # sandbox refuse to start. So this block is off by default and must be
  # opted into explicitly. The fork upstreaming is also blocked by a
  # separate issue (ambiguous shared socket ownership denies normal
  # subprocess patterns) — see the bug report under
  # ~/.../openshell-interactive-enforcement/docs/interactive-enforcement/.
  #
  # When the fork upstream is fixed, flip the default by editing
  # AGENTBOX_INTERACTIVE_POLICY default below.
  if is_truthy "${AGENTBOX_INTERACTIVE_POLICY:-}"; then
    local sb port secret
    sb=$(workspace_sandbox_name)
    port=$(decide_server_port_for_sandbox "$sb")
    secret=$(ensure_decide_secret "$sb")
    cat >> "$target" <<YAML

  # ---- interactive enforcement (opt-in via AGENTBOX_INTERACTIVE_POLICY=1) ----
  #
  # The single endpoint below is a DEMO: it gates *.example.com so you can
  # smoke-test the held-connection flow. To gate real hosts (e.g. your prod
  # API, *.github.com, billing dashboards), EDIT THIS FILE — duplicate the
  # endpoint block under \`endpoints:\` once per host you want held, change
  # the \`host:\` value, then run \`agentbox policy reload\`. The YAML file
  # is the single source of truth; agentbox does not maintain a parallel
  # env-based list.
  #
  # The three ingredients all need to be present for interactive to fire
  # (see docs/openshell-interactive-enforcement.md for why each matters;
  # getting any one wrong silently disables the path):
  #
  #   - protocol: rest        - enables openshell's L7 inspector, which is the
  #                             only path that consults \`enforcement.mode\`
  #   - access: full          - satisfies the L7 validator's "rules or access"
  #                             requirement; establishes the base allow set
  #   - deny_rules: [...]     - overrides the base allow with allowed=false on
  #                             every request, which is what triggers the
  #                             Interactive arm of the proxy decision
  #
  # Wildcard semantics: openshell's OPA glob uses '.' as a segment
  # delimiter, so '*.zone' matches subdomains of zone but NOT the apex.
  # List the apex separately if you need it. Bare '*' is rejected.
  #
  # Requires openshell built from the interactive-enforcement branch:
  #   https://github.com/vshalpnjabi/OpenShell/tree/interactive-enforcement
  # Stock openshell silently downgrades this to plain \`enforce\` (no
  # held-connection prompt); the L4 watcher path continues to work.
  interactive_gate:
    name: interactive-gate
    endpoints:
      - host: "*.example.com"
        port: 443
        protocol: rest
        enforcement:
          mode: interactive
          endpoint: http://host.openshell.internal:${port}/decide
          timeout_seconds: 120
          fallback: deny
          secret: ${secret}
        access: full
        deny_rules:
          - method: "*"
            path: "**"
    binaries:
      - { path: "**" }
YAML
  fi
}

ensure_workspace_policy() {
  # If user pinned a policy via .agentbox.toml, honor that and skip auto-create.
  if [ -n "$AGB_POLICY" ]; then
    [ -f "$AGB_POLICY" ] || warn "policy file '$AGB_POLICY' (from .agentbox.toml) not found"
    return 0
  fi
  if [ ! -f "$WORKSPACE_POLICY_FILE" ]; then
    log "writing default deny-all policy to $WORKSPACE_POLICY_FILE (edit to grant access)"
    write_default_policy "$WORKSPACE_POLICY_FILE"
  fi
  AGB_POLICY="$WORKSPACE_POLICY_FILE"
}

# Append an auto_* network policy rule to .agentbox.policy.yaml so user
# approvals survive `agentbox policy reload` AND sandbox destroy+recreate
# (both reset openshell's live policy to the on-disk file). Idempotent —
# duplicate (host, port, binary) tuples are skipped by rule-name lookup.
# Insertion happens INSIDE the network_policies: section so the YAML stays
# valid. Auto rules are name-prefixed `auto_` so `agentbox approve reset`
# can find and remove them later.
auto_policy_append() {
  local host="$1" port="$2" binary="$3"
  local f="$WORKSPACE_POLICY_FILE"
  [ -f "$f" ] || return 1

  # Build a deterministic, YAML-safe rule name from the tuple. Long names
  # are truncated + suffixed with a short hash to avoid collisions.
  local hsan bsan rule_name
  hsan=$(printf '%s' "$host"   | tr -c 'a-zA-Z0-9' '_')
  bsan=$(printf '%s' "$binary" | tr -c 'a-zA-Z0-9' '_')
  rule_name="auto_${hsan}_${port}_${bsan}"
  if [ ${#rule_name} -gt 80 ]; then
    local digest
    digest=$(printf '%s' "$rule_name" | shasum -a 256 | cut -c1-8)
    rule_name="${rule_name:0:60}_${digest}"
  fi

  # Idempotent: skip if a rule with this name already exists.
  if grep -qE "^  ${rule_name}:[[:space:]]*$" "$f" 2>/dev/null; then
    return 0
  fi

  # The rule block to insert (one trailing newline already present).
  local block
  printf -v block '  # auto-added by agentbox approval prompt (safe to delete)
  %s:
    name: %s
    endpoints:
      - { host: '\''%s'\'', port: %s }
    binaries:
      - { path: '\''%s'\'' }
' "$rule_name" "$rule_name" "$host" "$port" "$binary"

  # Insert just before the next top-level key after `network_policies:`,
  # or at EOF if network_policies is the last top-level section. Atomic
  # via tempfile + mv. Pass `block` through ENVIRON because BWK awk's `-v`
  # rejects literal newlines.
  local tmp
  tmp=$(mktemp -t agentbox-policy-edit.XXXXXX 2>/dev/null) || tmp="/tmp/agentbox-policy-edit-$$.yaml"
  AGB_BLOCK="$block" awk '
    BEGIN { block = ENVIRON["AGB_BLOCK"]; in_np = 0; inserted = 0 }
    /^network_policies:[[:space:]]*$/ { in_np = 1; print; next }
    in_np && /^[a-zA-Z]/ {
      if (!inserted) { printf "%s", block; inserted = 1 }
      in_np = 0
    }
    { print }
    END { if (in_np && !inserted) printf "%s", block }
  ' "$f" > "$tmp" 2>/dev/null

  if [ -s "$tmp" ]; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Remove every auto_* rule (and its preceding `# auto-added` comment) from
# .agentbox.policy.yaml. Returns 0 even if nothing was removed.
auto_policy_remove_all() {
  local f="$WORKSPACE_POLICY_FILE"
  [ -f "$f" ] || return 0
  local tmp
  tmp=$(mktemp -t agentbox-policy-edit.XXXXXX 2>/dev/null) || tmp="/tmp/agentbox-policy-edit-$$.yaml"
  awk '
    # state: skipping inside an auto rule
    BEGIN { skip = 0 }
    /^  # auto-added by agentbox/ { skip = 1; next }
    skip && /^  auto_[a-zA-Z0-9_]+:[[:space:]]*$/ { next }
    skip && /^    / { next }
    skip {
      skip = 0
      # fall through and print this line
    }
    { print }
  ' "$f" > "$tmp" 2>/dev/null

  if [ -s "$tmp" ]; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

agent_install_cmd() {
  case "$1" in
    claude)   printf '%s\n' 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    codex)    printf '%s\n' 'if ! command -v npm >/dev/null; then (command -v apt-get >/dev/null && apt-get update && apt-get install -y nodejs npm) || (command -v apk >/dev/null && apk add --no-cache nodejs npm); fi && npm install -g @openai/codex' ;;
    opencode) printf '%s\n' 'curl -fsSL https://opencode.ai/install | bash' ;;
    *) return 1 ;;
  esac
}

agent_ensure_installed() {
  local sandbox="$1" agent="$2"
  if openshell sandbox exec --name "$sandbox" --no-tty -- sh -c "command -v $agent >/dev/null" >/dev/null 2>&1; then
    return 0
  fi
  local install
  install=$(agent_install_cmd "$agent") || err "no install recipe for agent '$agent'"
  log "installing $agent inside sandbox $sandbox (one-time)"
  openshell sandbox exec --name "$sandbox" --no-tty -- sh -c "$install" >&2 \
    || err "failed to install $agent in sandbox $sandbox"
}

agent_auth_mapping() {
  # echoes "<host-source-file>::<sandbox-dest-file>" for the agent, or empty.
  case "$1" in
    claude)   echo "$HOME/.claude/.credentials.json::/sandbox/.claude/.credentials.json" ;;
    codex)    echo "$HOME/.codex/auth.json::/sandbox/.codex/auth.json" ;;
    opencode) echo "$HOME/.local/share/opencode/auth.json::/sandbox/.local/share/opencode/auth.json" ;;
    *) return 1 ;;
  esac
}

agent_skip_flag() {
  # echoes the permission-skip flag for the agent, or empty if none.
  case "$1" in
    claude)   echo "--dangerously-skip-permissions" ;;
    codex)    echo "--dangerously-bypass-approvals-and-sandbox" ;;
    opencode) echo "--dangerously-skip-permissions" ;;
    *) echo "" ;;
  esac
}

agent_env_token() {
  # Echoes "<ENV_VAR_NAME>=<TOKEN_VALUE>" for the agent (one line) or empty.
  # On macOS, claude code stores OAuth tokens in the system Keychain and only
  # rarely writes the on-disk .credentials.json — so the file uploaded into the
  # sandbox usually has an EXPIRED access token, and the refresh flow inside the
  # sandbox fails. The portable answer is a long-lived token from `claude
  # setup-token` saved to a known file; agentbox passes it via env var.
  case "$1" in
    claude)
      local f="$HOME/.claude/.agentbox-oauth-token"
      if [ -f "$f" ]; then
        local tok
        tok=$(tr -d "[:space:]" < "$f")
        [ -n "$tok" ] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY"
      fi
      ;;
    codex)
      [ -n "${OPENAI_API_KEY:-}" ] && printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
      ;;
    opencode)
      : ;;
  esac
}

upload_agent_credentials() {
  # Seed sandbox with the host's auth so the agent is auto-authenticated and
  # doesn't show the first-run "Select login method" screen.
  #
  # For claude specifically: synthesize a .credentials.json with the long-lived
  # OAuth token from `agentbox auth setup claude`. Just passing
  # CLAUDE_CODE_OAUTH_TOKEN via env var gives `claude --print` auth (sufficient
  # for non-interactive use), but the TUI's onboarding flow checks for a
  # claudeAiOauth blob on disk; without it the welcome screen pops every new
  # sandbox. Building the blob from the long-lived token satisfies both checks.
  #
  # For codex/opencode: just upload the host's auth.json verbatim.
  local sandbox="$1" agent="$2"
  is_truthy "${AGENTBOX_NO_AGENT_AUTH:-}" && return 0

  if [ "$agent" = "claude" ]; then
    upload_claude_credentials_synthetic "$sandbox"
    return 0
  fi

  local mapping src dest dest_dir
  mapping=$(agent_auth_mapping "$agent") || return 0
  [ -z "$mapping" ] && return 0
  src="${mapping%%::*}"
  dest="${mapping##*::}"
  [ -f "$src" ] || return 0
  dest_dir=$(dirname "$dest")

  openshell sandbox exec --name "$sandbox" --no-tty -- mkdir -p "$dest_dir" </dev/null >/dev/null 2>&1 || true
  if openshell sandbox upload "$sandbox" "$src" "$dest" </dev/null >/dev/null 2>&1; then
    openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 "$dest" </dev/null >/dev/null 2>&1 || true
    log "synced host $agent credentials into sandbox ($dest)"
  else
    warn "$agent credential upload failed; agent inside sandbox will require interactive auth"
  fi
}

upload_claude_credentials_synthetic() {
  # Two files have to be on disk inside the sandbox for the claude TUI to
  # skip its first-run flow:
  #
  #   /sandbox/.claude/.credentials.json   provides the auth token (claudeAiOauth)
  #   /sandbox/.claude.json                provides hasCompletedOnboarding +
  #                                        oauthAccount info (skips welcome
  #                                        screen + login-method selection)
  #
  # Without #2, the TUI shows "Select login method" even with valid auth.
  local sandbox="$1"
  local token_file="$HOME/.claude/.agentbox-oauth-token"
  local host_creds="$HOME/.claude/.credentials.json"
  local host_global="$HOME/.claude.json"
  local tmpfile

  # 1. Build / upload .credentials.json
  if [ -f "$token_file" ]; then
    local tok
    tok=$(tr -d "[:space:]" < "$token_file")
    if [ -z "$tok" ]; then
      warn "claude long-lived token file is empty; agent will need interactive auth"
    else
      tmpfile=$(mktemp -t agentbox-cred) || return 1
      cat > "$tmpfile" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "$tok",
    "refreshToken": "$tok",
    "expiresAt": 9999999999999,
    "scopes": ["user:profile", "user:inference"],
    "subscriptionType": "pro",
    "rateLimitTier": "default"
  }
}
EOF
      openshell sandbox exec --name "$sandbox" --no-tty -- mkdir -p /sandbox/.claude </dev/null >/dev/null 2>&1 || true
      if openshell sandbox upload "$sandbox" "$tmpfile" /sandbox/.claude/.credentials.json </dev/null >/dev/null 2>&1; then
        openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 /sandbox/.claude/.credentials.json </dev/null >/dev/null 2>&1 || true
        log "synced synthetic claude credentials.json (from long-lived token)"
      else
        warn "claude synthetic credential upload failed"
      fi
      rm -f "$tmpfile"
    fi
  elif [ -f "$host_creds" ]; then
    openshell sandbox exec --name "$sandbox" --no-tty -- mkdir -p /sandbox/.claude </dev/null >/dev/null 2>&1 || true
    if openshell sandbox upload "$sandbox" "$host_creds" /sandbox/.claude/.credentials.json </dev/null >/dev/null 2>&1; then
      openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 /sandbox/.claude/.credentials.json </dev/null >/dev/null 2>&1 || true
      log "synced host ~/.claude/.credentials.json"
    fi
  else
    warn "no claude auth available — TUI will require interactive login"
  fi

  # 2. Upload .claude.json (the global onboarding state) so welcome screen
  # is skipped. Build a minimal version derived from host's file rather than
  # uploading the whole 68KB (which contains lots of host-specific state).
  if [ -f "$host_global" ]; then
    tmpfile=$(mktemp -t agentbox-claudejson) || return 1
    # Extract just the keys relevant for onboarding skip
    if command -v jq >/dev/null 2>&1; then
      jq '{
        hasCompletedOnboarding: (.hasCompletedOnboarding // true),
        lastOnboardingVersion: (.lastOnboardingVersion // "1.0.0"),
        firstStartTime: (.firstStartTime // "2024-01-01T00:00:00.000Z"),
        userID: (.userID // "agentbox-synthetic-user"),
        installMethod: (.installMethod // "native"),
        numStartups: (.numStartups // 1),
        oauthAccount: .oauthAccount,
        hasTrustDialogAccepted: true,
        bypassPermissionsModeAccepted: true,
        theme: (.theme // "dark"),
        autoUpdates: false,
        projects: {
          "/sandbox/work": {
            hasTrustDialogAccepted: true,
            allowedTools: [],
            mcpContextUris: [],
            mcpServers: {},
            enabledMcpjsonServers: [],
            disabledMcpjsonServers: [],
            hasClaudeMdExternalIncludesApproved: true,
            hasClaudeMdExternalIncludesWarningShown: true,
            projectOnboardingSeenCount: 1,
            exampleFiles: [],
            lastGracefulShutdown: true
          }
        }
      }' "$host_global" > "$tmpfile" 2>/dev/null
    else
      # Fallback: copy verbatim
      cp "$host_global" "$tmpfile"
    fi

    if openshell sandbox upload "$sandbox" "$tmpfile" /sandbox/.claude.json </dev/null >/dev/null 2>&1; then
      openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 /sandbox/.claude.json </dev/null >/dev/null 2>&1 || true
      log "synced /sandbox/.claude.json (hasCompletedOnboarding + oauthAccount; skips TUI welcome)"
    else
      warn "failed to upload /sandbox/.claude.json (welcome screen may appear)"
    fi
    rm -f "$tmpfile"
  fi
}

# Management subcommands
cmd_status() {
  printf '\n%s\n' "Sandboxes (agentbox-managed):"
  openshell sandbox list 2>/dev/null | awk 'NR==1 || /^agentbox-/'
  printf '\n%s\n' "Mutagen sync sessions:"
  mutagen sync list 2>/dev/null | awk '
    /^Name:/ {n=$2}
    /^Status:/ {s=$0; if (n ~ /^agentbox-/) print n"\t"s; n=""}
  ' | column -t -s $'\t'
  printf '\n%s\n' "Persisted session state (host):"
  if [ -d "$AGB_STATE_ROOT" ]; then
    du -sh "$AGB_STATE_ROOT"/*/ 2>/dev/null | column -t || echo "(empty)"
  else
    echo "(empty)"
  fi
}

cmd_stop() {
  local name="${1:-$(workspace_sandbox_name)}"
  log "stopping mutagen sync + watcher for $name (sandbox + state preserved)"
  watcher_stop "$name"
  decide_server_stop "$name"
  tmux_kill_session "$name"
  mutagen sync terminate "$name" >/dev/null 2>&1 || true
  mutagen sync terminate "${name}-state" >/dev/null 2>&1 || true
}

cmd_destroy() {
  # Host state at $AGB_STATE_ROOT/$name is the source of truth that gets
  # mutagen-synced INTO the sandbox on each launch (claude project history,
  # watcher seen-list, decide-server cache + secret, audit log). It is
  # never deleted by destroy — destroy is a sandbox-lifecycle operation,
  # not a state-eraser. The legacy --purge flag is still accepted for
  # backwards compatibility but is now a no-op for host state (we warn).
  local purge=0
  local name=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && name=$(workspace_sandbox_name)
  log "destroying $name (sandbox + sync + ssh block; host state preserved at $AGB_STATE_ROOT/$name)"
  if [ "$purge" -eq 1 ]; then
    warn "--purge is deprecated and no longer removes host state."
    warn "Host state ($AGB_STATE_ROOT/$name) is the source of truth and is always preserved."
    warn "To remove it, delete the directory manually: rm -rf '$AGB_STATE_ROOT/$name'"
  fi
  watcher_stop "$name"
  decide_server_stop "$name"
  tmux_kill_session "$name"
  mutagen sync terminate "$name" >/dev/null 2>&1 || true
  mutagen sync terminate "${name}-state" >/dev/null 2>&1 || true
  openshell sandbox delete "$name" >/dev/null 2>&1 || true
  if [ -f "$SSH_CONFIG" ]; then
    local start_marker="# agentbox:start $name"
    local end_marker="# agentbox:end $name"
    awk -v s="$start_marker" -v e="$end_marker" '
      $0 == s { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$SSH_CONFIG" > "$SSH_CONFIG.agbtmp"
    mv "$SSH_CONFIG.agbtmp" "$SSH_CONFIG"
  fi
}

cmd_pull() {
  local name="${1:-$(workspace_sandbox_name)}"
  log "flushing mutagen sync $name (workspace + state)"
  mutagen sync flush "$name" 2>/dev/null || true
  mutagen sync flush "${name}-state" 2>/dev/null || true
}

cmd_decide() {
  # Subcommands under `agentbox decide`: status | test | logs | seen | start | stop.
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    status) cmd_decide_status "$@" ;;
    test)   cmd_decide_test "$@" ;;
    logs)   cmd_decide_logs "$@" ;;
    seen)   cmd_decide_seen "$@" ;;
    start)  cmd_decide_start "$@" ;;
    stop)   cmd_decide_stop "$@" ;;
    *) err "unknown 'decide' subcommand '$sub' (try: agentbox decide status|test|logs|seen|start|stop)" ;;
  esac
}

cmd_decide_status() {
  local sandbox="${1:-$(workspace_sandbox_name)}"
  printf 'sandbox: %s\n' "$sandbox"
  if is_truthy "${AGENTBOX_NO_DECIDE_SERVER:-}"; then
    printf 'AGENTBOX_NO_DECIDE_SERVER: set → decide-server disabled (using legacy direct prompt path)\n'
  else
    printf 'decide-server: enabled (default; AGENTBOX_NO_DECIDE_SERVER=1 to opt out)\n'
  fi
  local bind="${AGENTBOX_DECIDE_BIND:-127.0.0.1}"
  if decide_server_running "$sandbox"; then
    local pid port
    pid=$(cat "$(decide_server_pid_file "$sandbox")" 2>/dev/null)
    port=$(cat "$(decide_server_port_file "$sandbox")" 2>/dev/null)
    printf 'status: running\n'
    printf 'pid: %s\n' "$pid"
    printf 'port: %s\n' "$port"
    printf 'bind: %s\n' "$bind"
    printf 'endpoint (from host):    http://127.0.0.1:%s/decide\n' "$port"
    if [ "$bind" != "127.0.0.1" ]; then
      printf 'endpoint (from sandbox): http://host.openshell.internal:%s/decide\n' "$port"
    fi
    printf 'log: %s\n' "$(decide_server_log_file "$sandbox")"
  else
    printf 'status: not running\n'
    local port
    port=$(decide_server_port_for_sandbox "$sandbox")
    printf 'would-use-port: %s (deterministic from sandbox hash)\n' "$port"
    printf 'would-use-bind: %s (AGENTBOX_DECIDE_BIND to override; 0.0.0.0 for in-container proxy)\n' "$bind"
  fi
}

cmd_decide_start() {
  # Manual start (the agent dispatch starts this automatically; this lets
  # you exercise the path without launching an agent). Respects
  # AGENTBOX_NO_DECIDE_SERVER opt-out for consistency — pass --force to
  # override that for one-off testing.
  local sandbox="${1:-$(workspace_sandbox_name)}"
  if is_truthy "${AGENTBOX_NO_DECIDE_SERVER:-}" && [ "${2:-}" != "--force" ]; then
    warn "AGENTBOX_NO_DECIDE_SERVER=1 — pass --force to override and start anyway"
    AGENTBOX_NO_DECIDE_SERVER=0 decide_server_ensure "$sandbox"
  else
    decide_server_ensure "$sandbox"
  fi
  # Python forks then writes pid+port; poll briefly so status shows the
  # running server rather than "not running" immediately after start.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    decide_server_running "$sandbox" && break
    sleep 0.2
  done
  cmd_decide_status "$sandbox"
}

cmd_decide_stop() {
  local sandbox="${1:-$(workspace_sandbox_name)}"
  decide_server_stop "$sandbox"
  log "decide-server stopped for $sandbox"
}

cmd_decide_logs() {
  local sandbox="${1:-$(workspace_sandbox_name)}"
  local log
  log=$(decide_server_log_file "$sandbox")
  if [ ! -f "$log" ]; then
    err "no decide-server log at $log"
  fi
  exec tail -n 200 -f "$log"
}

cmd_decide_seen() {
  # Show cached decisions for the current sandbox's decide-server.
  local sandbox="${1:-$(workspace_sandbox_name)}"
  local seen
  seen=$(decide_server_seen_file "$sandbox")
  if [ ! -s "$seen" ]; then
    printf '(no cached decisions yet for %s)\n' "$sandbox"
    return 0
  fi
  printf 'cached decisions for %s (%s):\n' "$sandbox" "$seen"
  awk -F '|' '{printf "  %-5s %s -> %s:%s\n", toupper($4), $1, $2, $3}' "$seen"
}

cmd_decide_test() {
  # Send a synthetic /decide POST through the running server. Useful for
  # exercising the prompt UI without needing openshell Interactive upstream.
  local host="${1:-github.com}"
  local port="${2:-443}"
  local binary="${3:-/usr/local/bin/claude}"
  local sandbox
  sandbox=$(workspace_sandbox_name)

  # Auto-ensure the server. `decide test` only makes sense when the user wants
  # to talk to the endpoint — so silently starting it on demand is the right
  # default. Idempotent: no-op if already running.
  if ! decide_server_running "$sandbox"; then
    decide_server_ensure "$sandbox"
    # Python forks and writes pid+port; poll briefly so the test doesn't race
    # the bind. ~1s is plenty in practice; cap at 3s to fail fast on bugs.
    local i
    for i in 1 2 3 4 5 6; do
      decide_server_running "$sandbox" && break
      sleep 0.5
    done
    if ! decide_server_running "$sandbox"; then
      err "decide-server failed to start for $sandbox — check 'agentbox decide logs'"
    fi
  fi
  if ! command -v jq >/dev/null 2>&1; then
    err "jq required for 'agentbox decide test' (brew install jq)"
  fi
  if ! command -v curl >/dev/null 2>&1; then
    err "curl required for 'agentbox decide test'"
  fi

  local srv_port
  srv_port=$(cat "$(decide_server_port_file "$sandbox")")
  local body
  body=$(jq -n \
    --arg host "$host" \
    --argjson port "$port" \
    --arg binary "$binary" \
    --arg sb "$sandbox" \
    --arg rid "test-$(date +%s)" \
    '{schema_version:1, request_id:$rid, host:$host, port:$port, binary:$binary, pid:0, method:"GET", path:"/", protocol:"rest", policy_name:"manual_test", sandbox_name:$sb}')

  log "POST http://127.0.0.1:$srv_port/decide  $binary -> $host:$port"
  local secret=""
  [ -f "$(decide_server_secret_file "$sandbox")" ] && \
    secret=$(cat "$(decide_server_secret_file "$sandbox")" 2>/dev/null || true)
  if [ -n "$secret" ]; then
    curl -fsS -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $secret" \
      --data "$body" "http://127.0.0.1:$srv_port/decide"
  else
    curl -fsS -X POST -H "Content-Type: application/json" --data "$body" "http://127.0.0.1:$srv_port/decide"
  fi
  echo
}

cmd_shell() {
  local name="${1:-$(workspace_sandbox_name)}"
  exec openshell sandbox exec --name "$name" --tty --workdir /sandbox/work -- /bin/sh -lc 'exec ${SHELL:-/bin/bash} -l'
}

cmd_ssh() {
  # SSH into the workspace's sandbox via the agentbox-managed ~/.ssh/config
  # block. Uses ssh -t for a real PTY end-to-end (CLAUDE.md rule 6 — cleaner
  # than openshell sandbox exec --tty for TUIs). Without trailing args, opens
  # an interactive shell. With args, runs them as a one-shot command.
  #
  # Examples:
  #   agentbox ssh                        # interactive shell, cwd=/sandbox/work
  #   agentbox ssh -- ls -la              # one-shot; -- prevents flag parsing
  #   agentbox ssh agentbox-foo-abc12345 cat /etc/os-release
  local name=""
  if [ "$#" -gt 0 ] && [[ "${1:-}" == agentbox-* ]]; then
    name="$1"; shift
  else
    name=$(workspace_sandbox_name)
  fi
  # `--` is a convention for "stop parsing flags" — allow but skip it.
  [ "${1:-}" = "--" ] && shift

  local phase
  phase=$(sandbox_phase "$name")
  if [ "$phase" != "Ready" ]; then
    err "sandbox '$name' not running (phase: ${phase:-not found}). Launch an agent first, or 'agentbox status'."
  fi
  ssh_config_sync "$name"

  # Bring up the approval prompt infrastructure so commands run inside this
  # SSH session (e.g. `gh auth login`, `pip install …`) get an interactive
  # prompt on L4 deny — same as commands run by an agent. Both ensures are
  # idempotent: no-op if already alive. Without these, a user SSHing in and
  # running a network command on a denied host just sees 403 with no prompt.
  watcher_ensure "$name"
  decide_server_ensure "$name"

  local ssh_host="openshell-$name"
  if [ "$#" -eq 0 ]; then
    log "ssh into $name (workdir=/sandbox/work) — exit to return"
    exec ssh -t "$ssh_host" "cd /sandbox/work && exec \${SHELL:-/bin/bash} -l"
  else
    # Shell-quote each arg so the remote shell sees them safely as a command.
    local quoted=""
    for a in "$@"; do
      quoted+=" $(printf '%q' "$a")"
    done
    log "ssh exec in $name:$quoted"
    exec ssh -t "$ssh_host" "cd /sandbox/work && exec${quoted}"
  fi
}

cmd_attach() {
  # Reattach to the tmux session for a workspace's agent (created when
  # agentbox wraps the agent launch in tmux, default-on). Useful after
  # detaching with Ctrl-B d or after closing the terminal window.
  local name="${1:-$(workspace_sandbox_name)}"
  tmux_available || err "tmux not installed (brew install tmux)"
  local session
  session=$(tmux_session_for_sandbox "$name")
  if ! agb_tmux has-session -t "$session" 2>/dev/null; then
    err "no tmux session '$session' (run 'claude' / 'codex' / 'opencode' in this workspace to start one)"
  fi
  if [ -n "${TMUX:-}" ]; then
    err "already inside tmux. Detach (Ctrl-B d) first, then run: agentbox attach"
  fi
  apply_agentbox_tmux_settings "$session"
  # exec replaces this shell with tmux, so the agb_tmux function wouldn't be
  # available — inline `tmux -L "$AGB_TMUX_SOCKET"` instead.
  exec tmux -L "$AGB_TMUX_SOCKET" attach -d -t "$session"
}

# ---- workspace config (.agentbox.toml) ----
# Per-workspace overrides for sandbox resources (cpu, memory) and other knobs
# (image, policy). Static fields require destroy+recreate to take effect since
# openshell doesn't expose a live-resize API; the --apply flag does this in one
# step (state is preserved across destroy via mutagen state-sync).

agb_toml_set() {
  local file=".agentbox.toml"
  local key="$1" val="$2"
  [ ! -f "$file" ] && printf '# agentbox per-workspace config (auto-edited)\n' > "$file"
  if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    local tmp; tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { print k " = \"" v "\""; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    printf '%s = "%s"\n' "$key" "$val" >> "$file"
  fi
}

agb_toml_unset() {
  local file=".agentbox.toml" key="$1"
  [ ! -f "$file" ] && return 0
  local tmp; tmp=$(mktemp)
  awk -v k="$key" '$0 !~ "^[[:space:]]*"k"[[:space:]]*=" { print }' "$file" > "$tmp" && mv "$tmp" "$file"
  # Tidy: remove empty/comment-only files
  if [ -z "$(grep -v '^[[:space:]]*\(#\|$\)' "$file")" ]; then
    rm -f "$file"
  fi
}

cmd_resize() {
  # Adjust sandbox resources for this workspace. Writes to .agentbox.toml,
  # then either tells the user to destroy+recreate or does it for them.
  #
  # Examples:
  #   agentbox resize                    # show effective config
  #   agentbox resize show               # same
  #   agentbox resize cpu 4              # set cpu
  #   agentbox resize cpu 4 memory 4Gi   # set multiple
  #   agentbox resize cpu 4 --apply      # set + destroy + auto-recreate
  #   agentbox resize unset cpu          # revert cpu to default
  local apply=0
  local pending_unset=0
  local pairs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply|--recreate|-a) apply=1; shift ;;
      show|"")               cmd_resize_show; return 0 ;;
      help|-h|--help)        cmd_resize_show; return 0 ;;
      unset)                 pending_unset=1; shift ;;
      cpu|memory|disk|image|policy)
        if [ "$pending_unset" -eq 1 ]; then
          pairs+=("__unset__:$1")
          pending_unset=0
          shift
        else
          [ -z "${2:-}" ] && err "missing value for '$1' (try: agentbox resize $1 4)"
          pairs+=("$1:$2")
          shift 2
        fi
        ;;
      *) err "unknown 'resize' arg: '$1'. Try: agentbox resize show" ;;
    esac
  done

  if [ "${#pairs[@]}" -eq 0 ]; then
    cmd_resize_show
    return 0
  fi

  local p key val changed=0
  for p in "${pairs[@]}"; do
    key="${p%%:*}"; val="${p#*:}"
    if [ "$key" = "__unset__" ]; then
      agb_toml_unset "$val"
      log "unset $val (will use default on next launch)"
      changed=1
      continue
    fi
    case "$key" in
      disk)
        warn "openshell doesn't expose a disk-size flag; ignoring '$key'. Disk capacity comes from the Docker storage driver — adjust via Docker Desktop settings (Resources → Disk image size) for a global change."
        continue
        ;;
      cpu)
        case "$val" in [0-9]*) ;; *) err "cpu must be a number, got '$val'" ;; esac
        ;;
      memory)
        case "$val" in
          [0-9]*[GMK]i|[0-9]*[GMK]) ;;
          *) err "memory must be like '4Gi', '512Mi', '2G' — got '$val'" ;;
        esac
        ;;
    esac
    agb_toml_set "$key" "$val"
    log "set $key = $val"
    changed=1
  done

  [ "$changed" -eq 0 ] && return 0

  local name; name=$(workspace_sandbox_name)
  echo
  log "wrote $PWD/.agentbox.toml"
  log "openshell can't live-resize a running sandbox; the new values take effect on the NEXT sandbox creation."

  if [ "$apply" -eq 1 ]; then
    log "--apply: destroying $name now (workspace + state preserved on host)"
    cmd_destroy "$name"
    log "done. Next 'claude' / 'codex' / 'opencode' will create a fresh sandbox with the new resources."
  else
    local phase; phase=$(sandbox_phase "$name" 2>/dev/null || echo "")
    if [ "$phase" = "Ready" ]; then
      log "current sandbox '$name' is running with old values. To apply now:"
      log "  agentbox destroy && claude        # or codex / opencode"
      log "  (or re-run with --apply)"
    else
      log "no running sandbox; new values will apply on first agent launch."
    fi
  fi
}

cmd_sudo() {
  # Manage in-sandbox NOPASSWD sudo for the current workspace.
  #   agentbox sudo          show status
  #   agentbox sudo enable   write sudo=true to .agentbox.toml AND apply
  #                          to the running sandbox immediately (idempotent)
  #   agentbox sudo disable  remove /etc/sudoers.d/agentbox + drop from
  #                          .agentbox.toml
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    enable)  cmd_sudo_enable  "$@" ;;
    disable) cmd_sudo_disable "$@" ;;
    status|show|"") cmd_sudo_status "$@" ;;
    help|-h|--help) cmd_sudo_status "$@" ;;
    *) err "unknown 'sudo' subcommand '$sub' (try: agentbox sudo {enable|disable|status})" ;;
  esac
}

cmd_sudo_enable() {
  local name
  name=$(workspace_sandbox_name)
  agb_toml_set "sudo" "true"
  log "wrote sudo = true to $PWD/.agentbox.toml"
  local phase
  phase=$(sandbox_phase "$name" 2>/dev/null || echo "")
  if [ "$phase" = "Ready" ]; then
    log "applying to running sandbox $name now"
    setup_sandbox_sudo "$name" || warn "setup failed — see message above; restart sandbox with 'agentbox destroy && claude'"
  else
    log "no running sandbox; will apply on next agent launch."
  fi
  cmd_sudo_status
}

cmd_sudo_disable() {
  local name
  name=$(workspace_sandbox_name)
  agb_toml_unset "sudo"
  log "removed sudo from $PWD/.agentbox.toml"
  local phase
  phase=$(sandbox_phase "$name" 2>/dev/null || echo "")
  if [ "$phase" = "Ready" ]; then
    log "removing /etc/sudoers.d/agentbox from $name"
    local container
    if container=$(find_sandbox_container "$name") \
       && docker exec -u 0 "$container" /bin/sh -c 'rm -f /etc/sudoers.d/agentbox' >/dev/null 2>&1; then
      audit_emit "$name" "sudo" "DISABLED (sudoers file removed)"
      log "  ✓ sudo revoked inside $name"
    else
      warn "could not remove sudoers file. Manual cleanup:"
      warn "  container=\$(docker ps --filter name=$name --format '{{.ID}}' | head -1)"
      warn "  docker exec -u 0 \$container rm -f /etc/sudoers.d/agentbox"
    fi
  fi
  cmd_sudo_status
}

cmd_sudo_status() {
  local name
  name=$(workspace_sandbox_name)
  load_config
  printf '\n  workspace: %s\n' "$PWD"
  printf '  sandbox:   %s\n' "$name"
  echo

  # Config-file state
  if [ -f .agentbox.toml ] && grep -qE '^[[:space:]]*sudo[[:space:]]*=[[:space:]]*"?(true|1|yes|on)"?' .agentbox.toml 2>/dev/null; then
    printf '  .agentbox.toml:   sudo = true  (enabled, persistent)\n'
  else
    printf '  .agentbox.toml:   sudo not set (or false)\n'
  fi

  # Env var state
  if is_truthy "${AGENTBOX_SUDO:-}"; then
    printf '  AGENTBOX_SUDO:    set (enabled for this shell)\n'
  else
    printf '  AGENTBOX_SUDO:    unset\n'
  fi

  # Live sandbox state — only check if running
  local phase
  phase=$(sandbox_phase "$name" 2>/dev/null || echo "")
  if [ "$phase" = "Ready" ]; then
    if openshell sandbox exec --name "$name" --no-tty -- sudo -n true \
         </dev/null >/dev/null 2>&1; then
      printf '  live in sandbox:  ✓ sudo -n works (NOPASSWD active)\n'
    else
      printf '  live in sandbox:  ✗ sudo -n does not work (not yet applied or revoked)\n'
    fi
  else
    printf '  live in sandbox:  (sandbox not running)\n'
  fi
  echo
  echo "  agentbox sudo enable   # write sudo=true + apply to running sandbox"
  echo "  agentbox sudo disable  # remove sudoers + drop from .agentbox.toml"
  echo
}

cmd_resize_show() {
  # Print the effective config for the current workspace.
  load_config
  local name; name=$(workspace_sandbox_name)
  printf '\n  workspace: %s\n' "$PWD"
  printf '  sandbox:   %s\n' "$name"
  local phase; phase=$(sandbox_phase "$name" 2>/dev/null || echo "")
  printf '  phase:     %s\n' "${phase:-not created}"
  printf '\n  Effective config:\n'
  printf '    image:    %s\n' "$AGB_IMAGE"
  printf '    cpu:      %s\n' "$AGB_CPU"
  printf '    memory:   %s\n' "$AGB_MEMORY"
  [ -n "$AGB_POLICY" ] && printf '    policy:   %s\n' "$AGB_POLICY"
  printf '\n'
  if [ -f .agentbox.toml ]; then
    printf '  Source: .agentbox.toml overrides defaults:\n'
    sed 's/^/    /' .agentbox.toml
  else
    printf '  Source: defaults (no .agentbox.toml in workspace)\n'
  fi
  printf '\n  Set:    agentbox resize cpu 4 memory 4Gi\n'
  printf '  Apply:  agentbox resize cpu 4 memory 4Gi --apply\n'
  printf '  Unset:  agentbox resize unset cpu\n'
  printf '\n  (Disk size is not adjustable via openshell flags — comes from\n'
  printf '   the Docker storage driver. Adjust via Docker Desktop → Resources.)\n\n'
}

cmd_auth() {
  # Per-agent host-side auth setup. Each agent has its own credential file;
  # agentbox uploads them into the sandbox on every launch (and for claude,
  # also injects CLAUDE_CODE_OAUTH_TOKEN since macOS keychain isn't portable
  # to the Linux sandbox).
  #
  # Auth surfaces:
  #   claude    ~/.claude/.agentbox-oauth-token  (via `claude setup-token`)
  #   codex     ~/.codex/auth.json               (via `codex login`)
  #   opencode  ~/.local/share/opencode/auth.json (via `opencode auth login`)
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift
  local agent="${1:-claude}"
  [ "$#" -gt 0 ] && shift

  case "$sub" in
    setup)
      cmd_auth_setup "$agent"
      ;;
    status)
      cmd_auth_status
      ;;
    clear|remove)
      cmd_auth_clear "$agent"
      ;;
    *)
      err "usage: agentbox auth {setup|status|clear} [claude|codex|opencode|all]"
      ;;
  esac
}

cmd_auth_setup() {
  local agent="$1"
  case "$agent" in
    all)
      cmd_auth_setup claude
      echo >&2
      cmd_auth_setup codex
      echo >&2
      cmd_auth_setup opencode
      return 0
      ;;
    claude)
      local real_claude
      real_claude=$(real_binary "claude")
      [ -z "$real_claude" ] && err "no real claude binary recorded (run install.sh)"
      [ -x "$real_claude" ] || err "claude not executable at $real_claude"
      local tok_file="$HOME/.claude/.agentbox-oauth-token"
      mkdir -p "$(dirname "$tok_file")"
      log "claude: running '$real_claude setup-token' (interactive TUI)"
      log "  follow the prompts; agentbox will auto-capture the token from setup-token's output"
      echo >&2

      # Wrap setup-token in `script` so it gets a real pty (TUI animation +
      # cursor positioning work), while we silently capture the session
      # transcript to a temp file. After exit, parse the transcript and
      # extract the token via regex.
      local session_file
      session_file=$(mktemp -t agentbox-auth) || err "mktemp failed"
      trap "rm -f \"$session_file\"" RETURN

      if ! script -q "$session_file" "$real_claude" setup-token; then
        err "claude setup-token failed or was cancelled"
      fi

      echo >&2
      # Extract the token: strip ANSI escapes, find long base64-ish strings,
      # prefer ones that look like Anthropic OAuth tokens (often sk-ant-* or
      # a long mixed-case alnum/underscore/dash blob). Take the last match.
      local tok
      tok=$(python3 - "$session_file" <<PYEXTRACT
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", errors="replace")
# Strip ANSI CSI/OSC and other control chars
data = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", data)
data = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\\\)", "", data)
data = re.sub(r"[\x00-\x08\x0b-\x1f]", "", data)
# Prefer sk-ant-* if present; fall back to long base64-ish strings
m = re.findall(r"sk-ant-[A-Za-z0-9_-]{20,}", data)
if not m:
    m = [c for c in re.findall(r"[A-Za-z0-9_-]{50,}", data) if not c.lower().startswith("http")]
print(m[-1] if m else "")
PYEXTRACT
)

      if [ -z "$tok" ]; then
        warn "claude: couldn't auto-extract token from setup-token output."
        warn "  paste it manually (or Enter to skip):"
        printf '  Token: ' >&2
        IFS= read -r tok
        tok=$(printf '%s' "$tok" | tr -d "[:space:]")
      fi

      if [ -z "$tok" ]; then
        err "no token captured; nothing saved"
      fi

      printf '%s\n' "$tok" > "$tok_file"
      chmod 600 "$tok_file"
      log "claude: saved long-lived token to $tok_file (${#tok} chars, mode 600)"
      log "future agentbox sandbox claude launches will auto-inject CLAUDE_CODE_OAUTH_TOKEN"
      ;;
    codex)
      local real_codex
      real_codex=$(real_binary "codex")
      [ -z "$real_codex" ] && err "no real codex binary recorded (run install.sh)"
      [ -x "$real_codex" ] || err "codex not executable at $real_codex"
      log "codex: running '$real_codex login' (interactive)"
      log "  saves credentials to ~/.codex/auth.json (auto-uploaded to sandboxes)"
      "$real_codex" login || err "codex login failed"
      if [ -f "$HOME/.codex/auth.json" ]; then
        log "codex: auth.json present ($(wc -c < "$HOME/.codex/auth.json" | tr -d " ") bytes)"
      else
        warn "codex: ~/.codex/auth.json not found after login — verify with 'codex login status'"
      fi
      ;;
    opencode)
      local real_opencode
      real_opencode=$(real_binary "opencode")
      [ -z "$real_opencode" ] && err "no real opencode binary recorded (run install.sh)"
      [ -x "$real_opencode" ] || err "opencode not executable at $real_opencode"
      log "opencode: running '$real_opencode auth login' (interactive)"
      log "  saves credentials to ~/.local/share/opencode/auth.json (auto-uploaded to sandboxes)"
      "$real_opencode" auth login || err "opencode auth login failed"
      if [ -f "$HOME/.local/share/opencode/auth.json" ]; then
        log "opencode: auth.json present ($(wc -c < "$HOME/.local/share/opencode/auth.json" | tr -d " ") bytes)"
      else
        warn "opencode: auth.json not found — verify with 'opencode auth list'"
      fi
      ;;
    *)
      err "unknown agent '$agent' (valid: claude | codex | opencode | all)"
      ;;
  esac
}

cmd_auth_status() {
  local tok_file="$HOME/.claude/.agentbox-oauth-token"
  echo "agent     credential file                                 status"
  echo "--------  ---------------------------------------------  ---------------------"

  if [ -f "$tok_file" ]; then
    printf '%-8s  %-45s  %s\n' "claude" "$tok_file" "$(wc -c < "$tok_file" | tr -d " ") bytes"
  else
    printf '%-8s  %-45s  %s\n' "claude" "$tok_file" "NOT SET (agentbox auth setup claude)"
  fi

  if [ -f "$HOME/.codex/auth.json" ]; then
    printf '%-8s  %-45s  %s\n' "codex" "~/.codex/auth.json" "$(wc -c < "$HOME/.codex/auth.json" | tr -d " ") bytes"
  else
    printf '%-8s  %-45s  %s\n' "codex" "~/.codex/auth.json" "NOT SET (agentbox auth setup codex)"
  fi

  if [ -f "$HOME/.local/share/opencode/auth.json" ]; then
    printf '%-8s  %-45s  %s\n' "opencode" "~/.local/share/opencode/auth.json" "$(wc -c < "$HOME/.local/share/opencode/auth.json" | tr -d " ") bytes"
  else
    printf '%-8s  %-45s  %s\n' "opencode" "~/.local/share/opencode/auth.json" "NOT SET (agentbox auth setup opencode)"
  fi

  echo
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ANTHROPIC_API_KEY: set in env (${#ANTHROPIC_API_KEY} chars) — used as claude fallback"
  fi
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "OPENAI_API_KEY:    set in env (${#OPENAI_API_KEY} chars)    — forwarded to codex"
  fi
}

cmd_auth_clear() {
  local agent="$1"
  case "$agent" in
    all)
      cmd_auth_clear claude
      cmd_auth_clear codex
      cmd_auth_clear opencode
      ;;
    claude)
      local f="$HOME/.claude/.agentbox-oauth-token"
      [ -f "$f" ] && { rm -f "$f"; log "removed $f"; } || echo "claude: already cleared"
      ;;
    codex)
      local f="$HOME/.codex/auth.json"
      [ -f "$f" ] && { rm -f "$f"; log "removed $f"; } || echo "codex: already cleared"
      ;;
    opencode)
      local f="$HOME/.local/share/opencode/auth.json"
      [ -f "$f" ] && { rm -f "$f"; log "removed $f"; } || echo "opencode: already cleared"
      ;;
    *)
      err "unknown agent '$agent'"
      ;;
  esac
}

cmd_version() {
  # Print agentbox version + git rev when running from a tracked checkout.
  local rev=""
  local repo_dir
  repo_dir=$(dirname "$(readlink -f "$AGB_ROOT/agentbox.sh" 2>/dev/null || echo "$AGB_ROOT/agentbox.sh")")
  if [ -d "$repo_dir/.git" ] && command -v git >/dev/null 2>&1; then
    rev=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || true)
    local dirty=""
    if [ -n "$rev" ] && ! git -C "$repo_dir" diff --quiet HEAD 2>/dev/null; then
      dirty="-dirty"
    fi
    rev="${rev}${dirty}"
  fi
  if [ -n "$rev" ]; then
    printf 'agentbox %s (%s)\n' "$AGENTBOX_VERSION" "$rev"
  else
    printf 'agentbox %s\n' "$AGENTBOX_VERSION"
  fi
  printf '  source: https://github.com/vshalpnjabi/agentbox\n'
}

cmd_uninstall() {
  # Locate uninstall.sh (next to agentbox.sh, since they ship together) and exec it.
  local repo_dir
  repo_dir=$(dirname "$(readlink -f "$AGB_ROOT/agentbox.sh" 2>/dev/null || echo "$AGB_ROOT/agentbox.sh")")
  local script="$repo_dir/uninstall.sh"
  if [ ! -x "$script" ]; then
    err "uninstall.sh not found at $script — fetch it: curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/uninstall.sh | bash"
  fi
  exec "$script" "$@"
}

cmd_doctor() {
  # Health check: walk through every prerequisite agentbox needs and report
  # which are good / missing / unknown. Offer to open the right macOS settings
  # pane for the ones a user has to click through (Accessibility, Notifications).

  local fix_mode=0
  case "${1:-}" in --fix|fix) fix_mode=1 ;; esac

  local pass=0 fail=0 unknown=0
  local maybe_open_pane=()

  printf '\nagentbox doctor — version %s\n' "$AGENTBOX_VERSION"
  printf '%s\n' "---------------"

  _row() {
    # _row STATUS LABEL [HINT]
    local sym color
    case "$1" in
      ok)   sym="✓"; color="$c_green";  pass=$((pass+1)) ;;
      bad)  sym="✗"; color="$c_red";    fail=$((fail+1)) ;;
      warn) sym="!"; color="$c_yellow"; unknown=$((unknown+1)) ;;
      info) sym="·"; color="$c_blue" ;;
    esac
    printf '  %s%s%s  %-30s' "$color" "$sym" "$c_reset" "$2"
    [ -n "${3:-}" ] && printf '  %s%s%s' "$c_yellow" "$3" "$c_reset"
    printf '\n'
  }
  c_blue=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_reset=$'\033[0m'

  # ---- 1. CLI dependencies ----
  for entry in "openshell:nvidia/openshell/openshell" "mutagen:mutagen-io/mutagen/mutagen" "alerter:vjeantet/tap/alerter" "qrencode:qrencode" "jq:jq" "git:git" "tmux:tmux"; do
    cmd="${entry%%:*}"; spec="${entry##*:}"
    if command -v "$cmd" >/dev/null 2>&1; then
      _row ok "$cmd"
    else
      _row bad "$cmd" "brew install $spec"
    fi
  done

  # python3 — needed by the default-on decide-server. Without it the
  # watcher falls back to its direct prompt path (no regression, just
  # less unified state).
  if command -v python3 >/dev/null 2>&1; then
    _row ok "python3" "$(python3 --version 2>&1)"
  elif is_truthy "${AGENTBOX_NO_DECIDE_SERVER:-}"; then
    _row info "python3" "not needed (AGENTBOX_NO_DECIDE_SERVER=1)"
  else
    _row warn "python3" "missing — decide-server skipped; watcher uses fallback direct prompts"
  fi

  # In-sandbox sudo (only meaningful if AGENTBOX_SUDO is set for current workspace).
  # We can't easily check inside-sandbox state from here without naming a specific
  # sandbox, but we can report the env-var/toml settings.
  if [ -f .agentbox.toml ] && grep -qE '^[[:space:]]*sudo[[:space:]]*=[[:space:]]*"?(true|1|yes|on)"?' .agentbox.toml 2>/dev/null; then
    _row ok "sandbox sudo" "enabled via .agentbox.toml in $PWD"
  elif is_truthy "${AGENTBOX_SUDO:-}"; then
    _row ok "sandbox sudo" "enabled via AGENTBOX_SUDO env"
  else
    _row info "sandbox sudo" "disabled (AGENTBOX_SUDO=1 or .agentbox.toml sudo=true to enable)"
  fi

  # xdotool — only relevant for Linux force-retry keystroke injection.
  if [ "$(uname)" = "Linux" ]; then
    if command -v xdotool >/dev/null 2>&1; then
      _row ok "xdotool"
    elif is_truthy "${AGENTBOX_FORCE_RETRY:-}"; then
      _row bad "xdotool" "required by AGENTBOX_FORCE_RETRY on Linux (X11); install xdotool"
    else
      _row info "xdotool" "optional (only needed for AGENTBOX_FORCE_RETRY on Linux)"
    fi
  fi

  # ---- 2. Docker / compute driver ----
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      _row ok "Docker daemon"
    else
      _row bad "Docker daemon" "start Docker Desktop"
    fi
  else
    _row warn "Docker / Podman" "install Docker Desktop"
  fi

  # ---- 3. openshell gateway ----
  if brew services list 2>/dev/null | grep -qE "^openshell\s+started"; then
    _row ok "openshell gateway"
  else
    _row warn "openshell gateway" "brew services start openshell"
  fi

  # ---- 4. Accessibility permission for the terminal (alerter / osascript)
  # osascript on macOS requires "Accessibility" or "Automation" perm to
  # control System Events. Probe by querying running process names.
  if [ "$(uname)" = "Darwin" ]; then
    if osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
      _row ok "Accessibility (osascript)"
    else
      _row bad "Accessibility" "open System Settings → Privacy & Security → Accessibility; add Terminal"
      maybe_open_pane+=("accessibility")
    fi
  fi

  # ---- 5. Notifications permission for Terminal (alerter sender)
  # macOS doesn't expose a clean read API for per-app notification settings,
  # so we can only hint. Open the pane so the user can verify.
  if [ "$(uname)" = "Darwin" ]; then
    _row info "Notifications" "verify Terminal style = Alerts in System Settings"
    maybe_open_pane+=("notifications")
  fi

  # ---- 6. Long-lived claude token (optional but recommended)
  if [ -f "$HOME/.claude/.agentbox-oauth-token" ]; then
    local sz; sz=$(wc -c < "$HOME/.claude/.agentbox-oauth-token" | tr -d " ")
    _row ok "claude long-lived token" "$sz bytes"
  else
    _row warn "claude long-lived token" "agentbox auth setup claude"
  fi

  # ---- 7. codex / opencode auth
  if [ -f "$HOME/.codex/auth.json" ]; then
    _row ok "codex auth"
  else
    _row warn "codex auth" "agentbox auth setup codex"
  fi
  if [ -f "$HOME/.local/share/opencode/auth.json" ]; then
    _row ok "opencode auth"
  else
    _row warn "opencode auth" "agentbox auth setup opencode"
  fi

  # ---- 8. ntfy (optional)
  if [ -f "$AGB_NTFY_TOPIC_FILE" ]; then
    if is_truthy "${AGENTBOX_NTFY:-}"; then
      _row ok "ntfy.sh push"
    else
      _row warn "ntfy.sh push" "configured but disabled (export AGENTBOX_NTFY=1)"
    fi
  else
    _row info "ntfy.sh push" "optional; agentbox notify setup"
  fi

  # ---- 8b. Resolved notification backend (which one prompt_approval will use)
  local backend
  backend=$(notification_backend)
  case "$backend" in
    "none"*)      _row bad  "notification backend" "$backend" ;;
    "/dev/tty"*)  _row warn "notification backend" "$backend" ;;
    *)            _row ok   "notification backend" "$backend" ;;
  esac

  # ---- 9. Agents on PATH (the real binaries)
  for agent in claude codex opencode; do
    local real
    real=$(awk -F= -v a="$agent" '$1==a {print $2}' "$AGB_ORIGINALS" 2>/dev/null)
    if [ -n "$real" ] && [ -x "$real" ]; then
      _row ok "$agent binary" "$real"
    elif [ -n "$real" ]; then
      _row bad "$agent binary" "recorded but missing: $real"
    else
      _row warn "$agent binary" "not detected (re-run install.sh after installing)"
    fi
  done

  # ---- Summary
  printf '\n  '
  printf '%s%d pass%s · ' "$c_green" "$pass" "$c_reset"
  [ "$fail" -gt 0 ] && printf '%s%d fail%s · ' "$c_red" "$fail" "$c_reset" || printf '%d fail · ' "$fail"
  printf '%s%d warn%s\n\n' "$c_yellow" "$unknown" "$c_reset"

  # ---- Offer to open settings panes if Accessibility/Notifications need attention
  if [ "${#maybe_open_pane[@]}" -gt 0 ] && [ "$fix_mode" -eq 1 ]; then
    for pane in "${maybe_open_pane[@]}"; do
      case "$pane" in
        accessibility)
          log "opening Privacy & Security → Accessibility"
          open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
          ;;
        notifications)
          log "opening Notifications pane"
          open "x-apple.systempreferences:com.apple.preference.notifications" 2>/dev/null || true
          ;;
      esac
      sleep 1
    done
  elif [ "${#maybe_open_pane[@]}" -gt 0 ]; then
    printf '  Run %s\n\n' "agentbox doctor --fix   # to auto-open the relevant System Settings panes"
  fi

  return $((fail > 0))
}

cmd_audit() {
  # View the host-side audit log for a sandbox. Captures every openshell event
  # (network allows/denies/L7 inspections, with binary + pid + path/method)
  # plus structured [agentbox:*] entries from the watcher for user decisions.
  local sub="${1:-show}"
  [ "$#" -gt 0 ] && shift
  local name="${1:-$(workspace_sandbox_name)}"
  local log_file
  log_file=$(audit_log_file "$name")

  case "$sub" in
    show|cat)
      [ -f "$log_file" ] || err "no audit log for $name yet (run claude in this workspace first)"
      echo "$log_file ($(wc -l < "$log_file" | tr -d " ") lines, $(wc -c < "$log_file" | tr -d " ") bytes)"
      echo "---"
      cat "$log_file"
      ;;
    tail)
      [ -f "$log_file" ] || err "no audit log for $name yet"
      log "tailing $log_file (Ctrl-C to stop)"
      exec tail -F "$log_file"
      ;;
    grep|search)
      local pat="${1:-}"
      [ -z "$pat" ] && err "usage: agentbox audit grep <pattern> [NAME]"
      [ -f "$log_file" ] || err "no audit log for $name yet"
      grep -E "$pat" "$log_file" || echo "(no matches)"
      ;;
    path)
      echo "$log_file"
      ;;
    decisions)
      [ -f "$log_file" ] || err "no audit log for $name yet"
      grep "agentbox:decision" "$log_file" || echo "(no recorded decisions yet)"
      ;;
    denies)
      [ -f "$log_file" ] || err "no audit log for $name yet"
      grep "DENIED" "$log_file" | tail -50 || echo "(no denies in log)"
      ;;
    clear|truncate)
      [ -f "$log_file" ] || { echo "(no log to clear)"; return 0; }
      local before; before=$(wc -l < "$log_file" | tr -d " ")
      : > "$log_file"
      log "cleared $log_file ($before lines removed)"
      ;;
    *)
      err "usage: agentbox audit {show|tail|grep <pattern>|decisions|denies|path|clear} [NAME]"
      ;;
  esac
}

cmd_notify() {
  # Manage the ntfy.sh approval channel: a cross-device push notification
  # backend with true two-button inline actions. Generates a hard-to-guess
  # topic, saves it locally, and prints subscribe instructions.
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift

  case "$sub" in
    setup)
      # Args:
      #   [TOPIC]            Reuse an existing topic instead of generating one.
      #                      Bare ("my-topic"), URL, or host+path all accepted.
      #   --global | -g      Also persist AGENTBOX_NTFY_TOPIC + AGENTBOX_NTFY=1
      #                      to the user's shell rc (zsh/bash/fish/profile) so
      #                      every new shell picks it up automatically.
      # Cross-host workflow: pick a shared topic name, run
      #   agentbox notify setup --global my-shared-topic
      # on every Mac, subscribe once on your phone, done.
      local provided="" global=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --global|-g) global=1; shift ;;
          --) shift; break ;;
          -*) err "unknown flag: $1 (use: agentbox notify setup [--global] [TOPIC])" ;;
          *)  [ -z "$provided" ] && provided="$1" || err "unexpected extra argument: $1"
              shift ;;
        esac
      done
      local existing
      if existing=$(ntfy_get_topic); then
        local src; src=$(ntfy_topic_source)
        if [ "$src" = "env" ]; then
          echo "ntfy topic is currently set via \$AGENTBOX_NTFY_TOPIC: $existing"
          echo "(unset it to use a file-backed topic, or just keep the env var.)"
          return 0
        fi
        echo "ntfy topic already configured: $existing"
        printf 'Overwrite? [y/N] ' >&2
        local ans
        IFS= read -r ans
        [ "$ans" != "y" ] && [ "$ans" != "Y" ] && { echo "(unchanged)"; return 0; }
      fi
      mkdir -p "$AGB_ROOT"
      local topic
      if [ -n "$provided" ]; then
        topic=$(ntfy_sanitize_topic "$provided") || \
          err "invalid topic '$provided' — use 1-64 chars [A-Za-z0-9_-]"
        log "reusing supplied ntfy topic: $topic"
      else
        topic="agentbox-$(uuidgen 2>/dev/null | tr "A-Z" "a-z" | tr -d "-" | head -c 24)"
        [ "${#topic}" -lt 24 ] && topic="agentbox-$(printf '%s' "$RANDOM$RANDOM$RANDOM$$" | shasum -a 256 | cut -c1-24)"
      fi
      printf '%s\n' "$topic" > "$AGB_NTFY_TOPIC_FILE"
      chmod 600 "$AGB_NTFY_TOPIC_FILE"
      log "saved ntfy topic to $AGB_NTFY_TOPIC_FILE"
      if [ "$global" = "1" ]; then
        local rc; rc=$(_persist_ntfy_env set "$topic")
        log "persisted AGENTBOX_NTFY_TOPIC + AGENTBOX_NTFY=1 to $rc"
        log "open a new shell (or 'source $rc') to pick it up in this session"
      fi
      echo
      echo "============================================================"
      echo "Topic URL:  $AGB_NTFY_BASE/$topic"
      echo "============================================================"
      echo
      echo "STEP 1: Subscribe to this topic on at least one device."
      echo
      if command -v qrencode >/dev/null 2>&1; then
        echo "  Phone: scan this QR with the ntfy app to subscribe:"
        echo
        qrencode -t UTF8 -o - "$AGB_NTFY_BASE/$topic" 2>/dev/null
        echo
      else
        echo "  Phone: install qrencode (brew install qrencode) for a scannable QR."
        echo
      fi
      if [ "$(uname)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
        # Prefer the installed ntfy macOS app when present (no URL scheme it
        # exposes, so we copy the topic to clipboard and open the app — user
        # taps + and pastes). Override with AGENTBOX_NTFY_SUBSCRIBE=browser|app|none.
        local sub_mode="${AGENTBOX_NTFY_SUBSCRIBE:-auto}"
        local ntfy_app_path="/Applications/ntfy.app"
        if [ "$sub_mode" = "none" ]; then
          echo "  Mac:   skipping auto-subscribe (AGENTBOX_NTFY_SUBSCRIBE=none)."
        elif [ "$sub_mode" = "browser" ]; then
          echo "  Mac:   opening $AGB_NTFY_BASE/$topic in your default browser."
          open "$AGB_NTFY_BASE/$topic" 2>/dev/null || true
        elif [ "$sub_mode" = "app" ] || { [ "$sub_mode" = "auto" ] && [ -d "$ntfy_app_path" ]; }; then
          if printf '%s' "$topic" | pbcopy 2>/dev/null; then
            echo "  Mac:   opening ntfy.app. Topic is now in your clipboard."
            echo "         Tap the + button in the app, paste, subscribe."
          else
            echo "  Mac:   opening ntfy.app. Paste this topic in the + button:"
            echo "           $topic"
          fi
          open -a ntfy 2>/dev/null || open "$ntfy_app_path" 2>/dev/null || true
        else
          echo "  Mac:   opening $AGB_NTFY_BASE/$topic in your default browser."
          echo "         (install ntfy macOS app for native pushes, or set"
          echo "          AGENTBOX_NTFY_SUBSCRIBE=app once you have it)"
          open "$AGB_NTFY_BASE/$topic" 2>/dev/null || true
        fi
      else
        echo "  Desktop: open $AGB_NTFY_BASE/$topic in a browser; allow notifications."
      fi
      echo "  Manual: paste topic '$topic' into the ntfy app's + button."
      echo
      echo "STEP 2: Once a device is subscribed, press Enter to send a test."
      echo "        (Ctrl+C to skip)"
      printf '       > ' >&2
      IFS= read -r _ || true
      echo
      echo "Sending test notification..."
      if curl -fsS -X POST \
            -H "Title: agentbox: setup complete" \
            -H "Priority: default" \
            -H "Tags: white_check_mark" \
            -d "approvals will arrive here. Opt-out: AGENTBOX_NO_NTFY=1" \
            "$AGB_NTFY_BASE/$topic" >/dev/null 2>&1; then
        echo "  test notification sent. Check your subscribed devices."
        echo "  If you do not see it: run 'agentbox notify open' or rescan the QR."
        echo
        echo "FINAL STEP: enable ntfy by exporting AGENTBOX_NTFY=1 in your shell:"
        echo "  echo 'export AGENTBOX_NTFY=1' >> ~/.zshrc && exec zsh"
        echo "(without this, agentbox still uses alerter even with the topic saved.)"
      else
        warn "  test notification POST failed (network issue?)"
      fi
      ;;
    status)
      local t
      if t=$(ntfy_get_topic); then
        local src; src=$(ntfy_topic_source)
        echo "ntfy topic: $t"
        echo "URL:        $AGB_NTFY_BASE/$t"
        case "$src" in
          env)  echo "Source:     \$AGENTBOX_NTFY_TOPIC env var (per-shell override)" ;;
          file) echo "Source:     $AGB_NTFY_TOPIC_FILE" ;;
        esac
        if is_truthy "${AGENTBOX_NTFY:-}"; then
          echo "Enabled:    yes (AGENTBOX_NTFY=1 set in env)"
        else
          echo "Enabled:    NO  (set AGENTBOX_NTFY=1 in your shell to activate)"
        fi
      else
        echo "ntfy: not configured  (run: agentbox notify setup)"
        echo "Tips:"
        echo "  - reuse a topic across machines: agentbox notify setup <topic>"
        echo "  - or per-shell override:         export AGENTBOX_NTFY_TOPIC=<topic>"
        echo "  - then activate:                 export AGENTBOX_NTFY=1"
      fi
      ;;
    test)
      local t
      t=$(ntfy_get_topic) || err "no topic configured (run: agentbox notify setup)"
      log "sending test notification with Allow/Deny actions to $t"
      local result
      result=$(ntfy_prompt "$t" "test-sandbox" "example.com" "443" "/usr/bin/curl")
      echo "you clicked: [$result]"
      ;;
    clear|remove)
      # Also accepts --global to strip the env block from the shell rc.
      local clear_global=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --global|-g) clear_global=1; shift ;;
          *) shift ;;
        esac
      done
      local cleared=0
      if [ -f "$AGB_NTFY_TOPIC_FILE" ]; then
        rm -f "$AGB_NTFY_TOPIC_FILE"
        log "removed ntfy topic file"
        cleared=1
      fi
      if [ "$clear_global" = "1" ]; then
        local rc; rc=$(_persist_ntfy_env unset)
        log "removed agentbox ntfy env block from $rc (open a new shell to pick up)"
        cleared=1
      fi
      [ "$cleared" = "0" ] && echo "(already cleared; pass --global to also strip shell rc)"
      ;;
    open)
      local t
      t=$(ntfy_get_topic) || err "no topic configured (run: agentbox notify setup)"
      command -v open >/dev/null 2>&1 || err "no 'open' command available"
      if [ -d /Applications/ntfy.app ] && [ "${AGENTBOX_NTFY_SUBSCRIBE:-auto}" != "browser" ]; then
        printf '%s' "$t" | pbcopy 2>/dev/null && log "topic copied to clipboard"
        log "opening ntfy.app (paste topic in the + button)"
        open -a ntfy 2>/dev/null || open /Applications/ntfy.app 2>/dev/null
      else
        log "opening $AGB_NTFY_BASE/$t in default browser"
        open "$AGB_NTFY_BASE/$t" 2>/dev/null || err "could not open browser"
      fi
      ;;
    browser)
      local t
      t=$(ntfy_get_topic) || err "no topic configured (run: agentbox notify setup)"
      log "opening $AGB_NTFY_BASE/$t in default browser (forced)"
      open "$AGB_NTFY_BASE/$t" 2>/dev/null || err "could not open browser"
      ;;
    qr)
      local t
      t=$(ntfy_get_topic) || err "no topic configured (run: agentbox notify setup)"
      command -v qrencode >/dev/null 2>&1 || err "qrencode not installed (brew install qrencode)"
      qrencode -t UTF8 -o - "$AGB_NTFY_BASE/$t"
      echo
      echo "Topic URL: $AGB_NTFY_BASE/$t"
      ;;
    *)
      err "usage: agentbox notify {setup|status|test|open|qr|clear}"
      ;;
  esac
}

cmd_notifications() {
  # Opens macOS System Settings to Notifications → Terminal so the user can
  # switch the notification style from "Banners" to "Alerts" (banners slide in
  # and disappear; alerts persist and show action buttons inline).
  if [ "$(uname)" != "Darwin" ]; then
    err "notifications setup is macOS-only"
  fi
  cat <<'EOF' >&2

In the pane that opens:
  1. Find "Terminal" in the list (or whichever sender agentbox impersonates).
  2. Set "Notification style" to "Alerts" (not Banners).
  3. Ensure "Allow notifications" is on and "Show actions" is checked.

Once that's set, agentbox approval prompts will appear as persistent
alerts with side-by-side Allow / Deny buttons.

EOF
  open "x-apple.systempreferences:com.apple.preference.notifications" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.Notifications-Settings.extension" 2>/dev/null \
    || { err "couldn't open System Settings — navigate manually to Settings → Notifications → Terminal"; }
}

cmd_approve() {
  # Manage the approval seen-lists AND the auto_* rules persisted in
  # .agentbox.policy.yaml. Two seen-list files for back-compat:
  #   decide-seen.txt   (canonical since v0.3.0)
  #   watcher-seen.txt  (legacy direct-mode + pre-v0.3.0)
  # reset wipes both seen-lists AND the auto_* rules in the policy file.
  local sub="${1:-list}"
  [ "$#" -gt 0 ] && shift
  local name="${1:-$(workspace_sandbox_name)}"
  local decide_seen="$AGB_STATE_ROOT/$name/decide-seen.txt"
  local watcher_seen="$AGB_STATE_ROOT/$name/watcher-seen.txt"
  case "$sub" in
    list)
      local any=0
      printf '%-50s  %-30s  %s\n' "BINARY" "HOST:PORT" "DECISION"
      for f in "$decide_seen" "$watcher_seen"; do
        [ -s "$f" ] || continue
        any=1
        awk -F'|' '{
          d = (NF >= 4 ? $4 : "(legacy)")
          printf "%-50s  %s:%-23s  %s\n", $1, $2, $3, d
        }' "$f"
      done
      if [ -f "$WORKSPACE_POLICY_FILE" ]; then
        local auto_count
        # grep -c prints '0' AND exits 1 on no matches; `|| echo 0` would
        # then append a second '0' making the value multiline. Use wc -l
        # on the matched lines instead so we get a single integer.
        auto_count=$(grep -cE '^  auto_[a-zA-Z0-9_]+:[[:space:]]*$' "$WORKSPACE_POLICY_FILE" 2>/dev/null)
        [ -z "$auto_count" ] && auto_count=0
        if [ "$auto_count" -gt 0 ]; then
          echo
          echo "  $auto_count auto_* rule(s) in $WORKSPACE_POLICY_FILE (persisted approvals)"
          any=1
        fi
      fi
      [ "$any" -eq 0 ] && echo "(no seen-list or auto rules for $name)"
      ;;
    forget)
      local pattern="${1:-}"
      [ -z "$pattern" ] && err "usage: agentbox approve forget <host-or-pattern> [NAME]"
      local total_removed=0
      for f in "$decide_seen" "$watcher_seen"; do
        [ -f "$f" ] || continue
        local before after
        before=$(wc -l < "$f" | tr -d ' ')
        grep -v "$pattern" "$f" > "$f.tmp" 2>/dev/null || true
        mv "$f.tmp" "$f"
        after=$(wc -l < "$f" | tr -d ' ')
        total_removed=$(( total_removed + (before - after) ))
      done
      log "removed $total_removed entries matching '$pattern' from seen-lists"
      log "Note: auto_* rules in $WORKSPACE_POLICY_FILE are not touched; edit by hand or use 'agentbox approve reset' to wipe all."
      ;;
    reset|clear)
      local n=0
      for f in "$decide_seen" "$watcher_seen"; do
        if [ -s "$f" ]; then
          n=$(( n + $(wc -l < "$f" | tr -d ' ') ))
          : > "$f"
        fi
      done
      log "cleared seen-list ($n entries removed across both files)"
      # Also remove auto_* rules from the workspace policy file.
      if [ -f "$WORKSPACE_POLICY_FILE" ]; then
        local before_auto after_auto
        before_auto=$(grep -cE '^  auto_[a-zA-Z0-9_]+:[[:space:]]*$' "$WORKSPACE_POLICY_FILE" 2>/dev/null); [ -z "$before_auto" ] && before_auto=0
        auto_policy_remove_all
        after_auto=$(grep -cE '^  auto_[a-zA-Z0-9_]+:[[:space:]]*$' "$WORKSPACE_POLICY_FILE" 2>/dev/null);  [ -z "$after_auto" ]  && after_auto=0
        log "removed $((before_auto - after_auto)) auto_* rule(s) from $WORKSPACE_POLICY_FILE"
      fi
      # Hot-reload the now-cleaner policy if the sandbox is running.
      if openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
        openshell policy set "$name" --policy "$WORKSPACE_POLICY_FILE" --wait >/dev/null 2>&1 && \
          log "hot-reloaded $WORKSPACE_POLICY_FILE on $name" || \
          warn "couldn't hot-reload (no running sandbox?)"
      fi
      ;;
    *)
      err "usage: agentbox approve {list|forget <pattern>|reset} [NAME]"
      ;;
  esac
}

cmd_policy() {
  local sub="${1:-show}"
  [ "$#" -gt 0 ] && shift
  local name="${1:-$(workspace_sandbox_name)}"
  case "$sub" in
    show)
      openshell policy get "$name" --full 2>&1
      ;;
    reload)
      local policy_path
      if [ -f "$WORKSPACE_POLICY_FILE" ]; then
        policy_path="$WORKSPACE_POLICY_FILE"
      else
        err "no $WORKSPACE_POLICY_FILE in $PWD (run 'claude' once to generate, or cd into the workspace)"
      fi
      log "pushing $policy_path -> sandbox $name (static fields ignored; only network_policies hot-reload)"
      openshell policy set "$name" --policy "$policy_path" --wait
      ;;
    edit)
      [ -f "$WORKSPACE_POLICY_FILE" ] || err "no $WORKSPACE_POLICY_FILE in $PWD (run 'claude' once to generate)"
      "${EDITOR:-vi}" "$WORKSPACE_POLICY_FILE"
      printf '\nRun "agentbox policy reload" to apply network changes to the running sandbox,\nor "agentbox destroy && claude" to apply static field changes.\n' >&2
      ;;
    reset)
      # Rewrite .agentbox.policy.yaml from the deny-all+defaults template (this
      # also wipes any auto_* rules accumulated from approval prompts), clear
      # the seen-list, and hot-reload network rules on the running sandbox.
      log "resetting .agentbox.policy.yaml in $PWD to default template (wipes auto_* rules too)"
      write_default_policy "$WORKSPACE_POLICY_FILE"
      local state_dir
      state_dir="$AGB_STATE_ROOT/$name"
      # Clear BOTH seen-lists. Reading-side (`get_seen_decision_for_key`)
      # checks decide-seen.txt FIRST, so leaving stale wildcard allows
      # there silently suppresses future prompts even after a "reset".
      # Earlier versions only cleared watcher-seen.txt which was the gap.
      for seen in "$state_dir/watcher-seen.txt" "$state_dir/decide-seen.txt"; do
        if [ -f "$seen" ]; then
          log "clearing seen-list ($seen)"
          : > "$seen"
        fi
      done
      if openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
        log "hot-reloading network policy on running sandbox $name"
        openshell policy set "$name" --policy "$WORKSPACE_POLICY_FILE" --wait 2>&1 | tail -3
      else
        log "no running sandbox $name; next 'claude' will apply the reset policy"
      fi
      log "done. Run 'agentbox destroy && claude' if you want static fields (filesystem/landlock/process) re-applied."
      ;;
    *)
      err "usage: agentbox policy {show|reload|edit|reset} [NAME]"
      ;;
  esac
}

cmd_name() {
  workspace_sandbox_name
}

cmd_help() {
  printf 'agentbox %s - per-workspace openshell sandboxes for AI coding agents\n' "$AGENTBOX_VERSION" >&2
  cat >&2 <<'EOF'

Management:
  agentbox status              List managed sandboxes, sync sessions, persisted state
  agentbox name                Print sandbox name for current workspace
  agentbox stop [NAME]         Pause workspace + state sync (sandbox preserved)
  agentbox pull [NAME]         Force-flush both sync sessions (workspace + state)
  agentbox shell [NAME]        Open interactive shell in sandbox
                               (via openshell exec; for basic shells)
  agentbox ssh [NAME] [-- cmd] Interactive shell OR one-shot command via
                               ssh -t (cleaner PTY for TUIs; supports
                               passing commands: 'agentbox ssh -- ls -la')
  agentbox attach [NAME]       Reattach to this workspace's tmux session
                               (created automatically when an agent runs)
  agentbox resize              Show effective sandbox config (cpu/memory/...)
  agentbox resize <key> <val>  Set a value in .agentbox.toml. Keys: cpu,
                               memory, image, policy. Examples:
                                 agentbox resize cpu 4
                                 agentbox resize memory 4Gi
                                 agentbox resize cpu 4 memory 4Gi --apply
                               --apply destroys + recreates the sandbox now
                               (host state preserved). Without --apply, run
                               'agentbox destroy && claude' to apply.
                               Disk size: not adjustable via openshell —
                               configure via Docker Desktop's storage driver.
  agentbox policy show [NAME]  Print active policy on sandbox
  agentbox policy edit [NAME]  Edit .agentbox.policy.yaml in $EDITOR
  agentbox policy reload [N]   Push workspace policy to running sandbox
  agentbox policy reset [N]    Restore default policy + wipe approval seen-list

Uninstall:
  agentbox uninstall                       Interactive tiered uninstall (asks
                                           per-tier: shims, sandboxes, ssh
                                           config, state, tokens, workspace files)
  agentbox uninstall --all                 Remove EVERYTHING (one summary prompt)
  agentbox uninstall --yes                 Non-interactive; remove default tier

Health check:
  agentbox doctor                          Walk every prerequisite + report
                                           pass/fail/warn (deps, Docker, gateway,
                                           Accessibility, Notifications, agent
                                           auth, ntfy, agent binaries).
  agentbox doctor --fix                    Same, plus auto-open System Settings
                                           panes for permissions that need clicks
                                           (Accessibility, Notifications).

Sandbox audit log (every openshell network event + watcher decisions,
persisted to host so they survive gateway restarts):
  agentbox audit show [NAME]               Print the full audit log
  agentbox audit tail [NAME]               Live-tail the log (Ctrl-C to stop)
  agentbox audit grep <pat> [NAME]         Filter the log by regex
  agentbox audit denies [NAME]             Show only DENIED entries (recent 50)
  agentbox audit decisions [NAME]          Show only Allow/Deny user decisions
  agentbox audit path [NAME]               Print log file path (~/.local/share/agentbox/state/<sandbox>/audit.log)
  agentbox audit clear [NAME]              Truncate the audit log

Approval prompts (DEFAULT: re-prompt on previously-denied tuples;
remember allows. Allow once → that host won't ask again. Deny → next
attempt will ask again so you can change your mind):
  agentbox approve list [N]              Show seen-list with decisions
  agentbox approve forget <pattern> [N]  Remove entries (so they prompt)
  agentbox approve reset [N]             Clear the entire seen-list
  export AGENTBOX_SUPPRESS_REPEATS=1     Suppress re-prompts for previously-
                                         denied tuples too (v0.1.0 mode).
                                         (Restart watcher: agentbox stop && claude)

Decide-server (host-side HTTP endpoint for openshell Interactive enforcement;
default-on; AGENTBOX_NO_DECIDE_SERVER=1 to disable):
  agentbox decide status                 Show running pid/port + endpoint URL
  agentbox decide start [NAME]           Manually start the server (auto-started
                                         on agent launch when env var is set)
  agentbox decide stop [NAME]            Stop the running server
  agentbox decide logs [NAME]            Tail the server log
  agentbox decide seen [NAME]            Show cached allow/deny decisions
  agentbox decide test [HOST [PORT [BIN]]]  Send a synthetic /decide POST
                                            (drives the prompt UI end-to-end
                                            without needing openshell upstream)

Notification appearance (macOS):
  agentbox notifications                 Open System Settings → Notifications →
                                         Terminal. Set "Notification style" to
                                         "Alerts" for persistent banner-style
                                         approval prompts with action buttons.

ntfy.sh (OPT-IN cross-device push with two-button inline actions):
  agentbox notify setup [--global] [TOPIC]
                                         Generate (or reuse, if TOPIC given) a
                                         topic, offer to open ntfy app / browser
                                         to subscribe, and send a test push.
                                         TOPIC can be bare ("my-topic") or a
                                         full URL ("https://ntfy.sh/my-topic").
                                         --global persists AGENTBOX_NTFY_TOPIC
                                         and AGENTBOX_NTFY=1 to your shell rc
                                         (zsh/bash/fish/profile) so every new
                                         shell auto-reuses it.
  agentbox notify status                 Topic + URL + source + enabled-or-not.
  agentbox notify open                   Re-open subscribe target (app/browser).
  agentbox notify browser                Re-open in browser specifically.
  agentbox notify qr                     Re-print the subscribe QR.
  agentbox notify test                   Trigger a test Allow/Deny prompt.
  agentbox notify clear [--global]       Remove the saved topic (and the env
                                         block from your shell rc with --global).

  Enable: export AGENTBOX_NTFY=1 in your shell, or use --global once. Without
  it ntfy stays dormant and prompts go through alerter (the default).
  Subscribe UX: AGENTBOX_NTFY_SUBSCRIBE=auto|app|browser|none

  Shared topic across hosts (laptop + remote Mac + phone subscribe once):
    Pick a topic name, then on EACH host run:
      agentbox notify setup --global my-shared-topic
    Subsequent new shells automatically have AGENTBOX_NTFY_TOPIC=my-shared-topic
    and AGENTBOX_NTFY=1 exported. Subscribe once on your phone — done.
    (Per-shell-only alternative: just export AGENTBOX_NTFY_TOPIC=<topic>
     manually; the env var beats the file when both are set.)

Per-agent host-side auth setup (so sandboxes auto-authenticate):
  agentbox auth status                          Show which agents are set up
  agentbox auth setup <claude|codex|opencode|all>
                                                Run agent's interactive login
                                                and stash the credential file.
  agentbox auth clear <claude|codex|opencode|all>
                                                Remove the agent's host credential.

  Credential layout (auto-uploaded into every sandbox):
    claude    ~/.claude/.agentbox-oauth-token  (long-lived token, injected as
                                                CLAUDE_CODE_OAUTH_TOKEN env)
    codex     ~/.codex/auth.json
    opencode  ~/.local/share/opencode/auth.json
  agentbox destroy [NAME]      Delete sandbox + ssh block. Host state at
                                ~/.local/share/agentbox/state/<sandbox>/ is
                                NEVER deleted (it is the source of truth that
                                mutagen-syncs INTO the sandbox on next launch).
  agentbox destroy --purge [N] Deprecated alias for `destroy [N]`. The --purge
                                flag is accepted but no longer wipes host state
                                (delete it manually with `rm -rf` if you really
                                want to).

Approval prompts (macOS):
  When an agent inside the sandbox hits a network deny (host:port not in
  policy), a background watcher SIGSTOPs the agent process(es) and pops a
  macOS dialog asking Allow/Deny — the TUI visibly pauses until you decide.
  Allow → `openshell policy update` hot-reloads the rule, agent resumes
  (the request that triggered the prompt still 403'd; retry succeeds).
  Deny → agent resumes and sees the 403. The (binary, host, port) is kept
  in ~/.local/share/agentbox/state/<sandbox>/watcher-seen.txt so you're
  not asked again for the same tuple. Opt out with AGENTBOX_NO_WATCH=1.

Tmux wrap (default-on; every TTY agent launch runs inside a dedicated
tmux session so the watcher can deliver retry-prompts via send-keys
regardless of focus, and you can detach/reattach without killing the
agent). Agentbox uses its own tmux SOCKET ('-L agentbox') so its key
bindings + options don't pollute your normal tmux config:
  Detach a session:           Ctrl-B then d
  Reattach:                   agentbox attach [NAME]
  List active sessions:       tmux -L agentbox ls  (NOT plain 'tmux ls')
  Opt out for one shell:      export AGENTBOX_NO_TMUX=1
  Custom socket name:         export AGENTBOX_TMUX_SOCKET=mysocket
  Mouse scrollback:           enabled by default. Disable: AGENTBOX_TMUX_MOUSE=off
  Scrollback depth:           AGENTBOX_TMUX_HISTORY=10000 (default)
  Click in copy-mode:         exits back to live input (override default
                              tmux behavior, which is sticky).
  Status bar (bottom):        shows 'agentbox <sandbox-name> | window-list'.
                              Override: AGENTBOX_TMUX_STATUS_LEFT="..."
                              (tmux format string), or
                              AGENTBOX_TMUX_STATUS_OFF=1 to hide entirely.
  Auto-skipped when already inside a tmux session (TMUX env set) — agentbox
  doesn't nest. Inside an outer tmux, retry-injection falls back to the
  keystroke path (which IS focus-dependent — see Force-retry caveats below).

Force-retry (auto-inject "retry the failed action" into the agent on Allow,
so you don't have to type it yourself):
  export AGENTBOX_FORCE_RETRY=1            Enable. Preferred path: tmux
                                           send-keys (focus-independent,
                                           requires the wrap above).
                                           Fallback when not wrapped: macOS
                                           osascript keystroke / Linux X11
                                           xdotool, both focus-dependent.
  export AGENTBOX_RETRY_PROMPT="..."       Override the injected text.
  export AGENTBOX_RETRY_DELAY=1            Seconds to wait before sending.
                                           Default UNSET on tmux path (no
                                           focus-settle needed). Keystroke
                                           fallback uses 1s for alerter
                                           dismiss + focus return.
  export AGENTBOX_RETRY_TYPING_DELAY=0.02  Per-char delay during the typing
                                           (defeats paste-detect mode in
                                           claude code; raising to 0.05 makes
                                           it more obviously human-paced).
  export AGENTBOX_RETRY_SUBMIT_DELAY=0.15  Pause after typing, before submit.
  export AGENTBOX_RETRY_SUBMIT_KEY="Enter" Key(s) to send to submit.
                                           Try if Enter doesn't submit:
                                             "Escape Enter"  (vim-style)
                                             "C-Enter"       (Ctrl+Enter)
                                             "M-Enter"       (Alt+Enter)
                                             "none"          (you press Enter)
  Caveat (keystroke fallback only): typing goes to whatever window has
  focus. The tmux send-keys path doesn't have this fragility.

Session continuity:
  /sandbox/.claude/projects (claude conversation history) is live-synced to
  ~/.local/share/agentbox/state/<sandbox>/ via a second mutagen session.
  `claude --continue` survives both `agentbox destroy` and out-of-band
  container loss; auto-recovery rebuilds the sandbox and restores state
  from host on the next `claude` invocation.

Launch (via shim symlinks):
  claude [args]                Launch claude in current workspace sandbox
  codex [args]                 Launch codex in current workspace sandbox
  opencode [args]              Launch opencode in current workspace sandbox

Bypass (run real binary, no sandbox):
  AGENTBOX_BYPASS=1 claude

Defaults when running claude through agentbox:
  - host ~/.claude/.credentials.json is auto-uploaded to the sandbox so the
    agent is authenticated without a browser auth flow (opt out: AGENTBOX_NO_CLAUDE_AUTH=1)
  - --dangerously-skip-permissions is prepended to claude args (the sandbox
    is your safety net; permission prompts inside become redundant friction).
    Opt out: AGENTBOX_PERMISSIONS=on, or pass the flag yourself.

Per-workspace policy:
  On first agent invocation in a workspace, agentbox writes
  .agentbox.policy.yaml (deny-all network, baseline filesystem only).
  Edit it to grant network/filesystem access; static fields take effect on
  `agentbox destroy && claude`, network_policies hot-reloads via
  `openshell policy update <sandbox>`.

Per-workspace overrides (.agentbox.toml in workspace root):
  image = "base"               openshell community image (base | ollama | ...)
  cpu = "1"
  memory = "1Gi"
  policy = "./custom.yaml"     override the auto-generated policy
  upload_credentials = false   if true, copies ~/.claude into sandbox
  sudo = true                  NOPASSWD sudo for the sandbox user (stays
                               inside the sandbox; opt-in, default false)

In-sandbox sudo (let the agent run 'sudo apt install foo', edit /etc/*, etc.
inside its OWN sandbox — no host escape):
  agentbox sudo                Show current sudo status (toml + env + live)
  agentbox sudo enable         Persist sudo=true in .agentbox.toml and apply
                               to the running sandbox immediately
  agentbox sudo disable        Revert: remove /etc/sudoers.d/agentbox and
                               drop sudo from .agentbox.toml

  Equivalent low-level toggles:
    export AGENTBOX_SUDO=1            enable for this shell only
    echo 'sudo = true' >> .agentbox.toml   persistent per-workspace

  Writes /etc/sudoers.d/agentbox with NOPASSWD for the sandbox user via a
  one-time `openshell sandbox exec --user root`. Idempotent — safe to leave
  on; subsequent launches detect and skip. If the base image lacks the sudo
  binary, falls back to a clear error with manual workaround.
EOF
}

# Dispatch
# Hidden subcommands that need to fire before $0-based routing.
if [ "${1:-}" = "__watch" ]; then
  shift
  cmd_watch_internal "$@"
  exit 0
fi
if [ "${1:-}" = "__decide" ]; then
  shift
  cmd_decide_handler_internal "$@"
  exit 0
fi
if [ "${1:-}" = "__backend" ]; then
  # Print which notification backend would be used. Useful for testing the
  # fallback chain (alerter → osascript → zenity → notify-send → /dev/tty).
  notification_backend
  exit 0
fi

self_name=$(basename "$0")

# Inside the sandbox, the shim shouldn't recurse. Just exec real binary.
if inside_sandbox && [ "$self_name" != "agentbox" ]; then
  exec "$self_name" "$@"  # PATH inside sandbox has the agents at standard locations
fi

# Explicit bypass
if is_truthy "${AGENTBOX_BYPASS:-}" && [ "$self_name" != "agentbox" ]; then
  real=$(real_binary "$self_name")
  [ -z "$real" ] && err "no real binary recorded for $self_name in $AGB_ORIGINALS"
  exec "$real" "$@"
fi

# Management CLI
if [ "$self_name" = "agentbox" ] || [ "$self_name" = "agentbox.sh" ]; then
  sub="${1:-help}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    status)  cmd_status "$@" ;;
    name)    cmd_name ;;
    stop)    cmd_stop "$@" ;;
    pull)    cmd_pull "$@" ;;
    shell)   cmd_shell "$@" ;;
    ssh)     cmd_ssh "$@" ;;
    attach)  cmd_attach "$@" ;;
    resize)  cmd_resize "$@" ;;
    sudo)    cmd_sudo "$@" ;;
    policy)  cmd_policy "$@" ;;
    approve)       cmd_approve "$@" ;;
    audit)         cmd_audit "$@" ;;
    decide)        cmd_decide "$@" ;;
    doctor)        cmd_doctor "$@" ;;
    uninstall)     cmd_uninstall "$@" ;;
    notifications) cmd_notifications "$@" ;;
    notify)        cmd_notify "$@" ;;
    auth)          cmd_auth "$@" ;;
    destroy) cmd_destroy "$@" ;;
    __watch) cmd_watch_internal "$@" ;;
    help|-h|--help)        cmd_help ;;
    version|-v|-V|--version) cmd_version ;;
    *) err "unknown subcommand '$sub' (try: agentbox help)" ;;
  esac
  exit 0
fi

# Agent dispatch
agent="$self_name"
agent_install_cmd "$agent" >/dev/null 2>&1 || err "unknown agent '$agent' (no install recipe; edit $AGB_ROOT/agentbox.sh)"

abs=$(cd "$PWD" && pwd -P)
case "$abs" in
  "$HOME"|/) err "refusing to sandbox $abs. cd into a workspace folder first." ;;
esac

load_config
ensure_workspace_policy
sandbox=$(workspace_sandbox_name)
sandbox_ensure "$sandbox" "$AGB_IMAGE" "$AGB_CPU" "$AGB_MEMORY" "$AGB_POLICY"

# Always seed agent credentials (set AGENTBOX_NO_AGENT_AUTH=1 to opt out)
upload_agent_credentials "$sandbox" "$agent"

# Default to the agent's permission-skip flag. The openshell sandbox itself enforces
# policy (network + filesystem), so per-tool-call approval prompts become redundant
# friction. Opt out: AGENTBOX_PERMISSIONS=on, or pass the flag yourself.
agb_skip_flag=$(agent_skip_flag "$agent")
if [ -n "$agb_skip_flag" ] && ! is_truthy "${AGENTBOX_PERMISSIONS:-}"; then
  has_skip=0
  for a in "$@"; do
    [ "$a" = "$agb_skip_flag" ] && { has_skip=1; break; }
  done
  if [ "$has_skip" -eq 0 ]; then
    case "$agent" in
      claude|codex)
        # Top-level flag; prepend.
        set -- "$agb_skip_flag" "$@"
        ;;
      opencode)
        # Only supported on the `run` subcommand; inject after it.
        if [ "${1:-}" = "run" ]; then
          sub="$1"; shift
          set -- "$sub" "$agb_skip_flag" "$@"
        fi
        ;;
    esac
  fi
fi

ssh_config_sync "$sandbox"
mutagen_ensure "$sandbox" "$PWD"
mutagen_state_ensure "$sandbox"
watcher_ensure "$sandbox"
decide_server_ensure "$sandbox"
# In-sandbox sudo: opt-in via AGENTBOX_SUDO=1 env or .agentbox.toml `sudo = true`.
# Idempotent — checks state first; no-op if already configured.
if is_truthy "${AGENTBOX_SUDO:-${AGB_SUDO:-false}}"; then
  setup_sandbox_sudo "$sandbox" || true
fi
agent_ensure_installed "$sandbox" "$agent"

# TTY: override > detect (stdout is a tty)
case "${AGENTBOX_TTY:-auto}" in
  on)  agb_want_tty=1 ;;
  off) agb_want_tty=0 ;;
  *)   [ -t 1 ] && agb_want_tty=1 || agb_want_tty=0 ;;
esac

if [ "$agb_want_tty" -eq 1 ]; then
  # Use SSH (via the agentbox-managed ~/.ssh/config block) for the interactive
  # path — openshell sandbox exec --tty's gRPC channel was observed to break
  # TUIs (each byte arrives line-buffered, terminal capability queries leak
  # through). SSH plumbs a real PTY end-to-end via the openshell ssh-proxy.
  ssh_host="openshell-$sandbox"
  quoted=""
  for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
  done
  # Inject auth env (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, OPENAI_API_KEY)
  # if the host has it. Properly shell-quoted for the remote shell.
  env_prefix=""
  env_line=$(agent_env_token "$agent")
  if [ -n "$env_line" ]; then
    env_var="${env_line%%=*}"
    env_val="${env_line#*=}"
    env_prefix="export $env_var=$(printf '%q' "$env_val") && "
    log "  injecting $env_var into sandbox (from host)"
  fi
  # Silence claude's "Native installation exists but ~/.local/bin is not in your
  # PATH" by ensuring the symlink and the PATH entry both exist inside the sandbox.
  setup_prefix="mkdir -p \$HOME/.local/bin && ln -sf /usr/local/bin/claude \$HOME/.local/bin/claude 2>/dev/null; export PATH=\$HOME/.local/bin:\$PATH && "
  inner_cmd="${setup_prefix}${env_prefix}cd /sandbox/work && exec $agent$quoted"

  if tmux_should_wrap; then
    tmux_session=$(tmux_session_for_sandbox "$sandbox")
    log "launching $agent in $sandbox (via tmux→ssh -t; session=$tmux_session)"
    log "  detach: Ctrl-B then d   |   reattach: agentbox attach"
    # Quote the ssh command for tmux's single-string command form.
    ssh_invoke=$(printf 'ssh -t %q %q' "$ssh_host" "$inner_cmd")
    # Create the session detached if it doesn't exist, then apply our
    # session-level settings (idempotent on every attach), then attach.
    # Splitting into three steps lets us apply settings — `new-session -A`
    # alone has no hook for that.
    if ! agb_tmux has-session -t "$tmux_session" 2>/dev/null; then
      agb_tmux new-session -d -s "$tmux_session" "$ssh_invoke"
    fi
    apply_agentbox_tmux_settings "$tmux_session"
    # -d detaches any other clients so a fresh window owns the session.
    # exec replaces this shell, so `agb_tmux` (a function) wouldn't be visible —
    # inline `tmux -L "$AGB_TMUX_SOCKET"` instead.
    exec tmux -L "$AGB_TMUX_SOCKET" attach -d -t "$tmux_session"
  else
    if [ -n "${TMUX:-}" ]; then
      warn "already inside tmux (TMUX=$TMUX); skipping agentbox tmux wrap (retry-injection will fall back to keystroke). Run from outside tmux to use the wrap."
    elif ! tmux_available && ! is_truthy "${AGENTBOX_NO_TMUX:-}"; then
      warn "tmux not installed; skipping wrap (retry-injection will fall back to keystroke). Install with: brew install tmux  (or set AGENTBOX_NO_TMUX=1 to silence)"
    fi
    log "launching $agent in $sandbox (via ssh -t, workdir=/sandbox/work)"
    exec ssh -t "$ssh_host" "$inner_cmd"
  fi
else
  log "launching $agent in $sandbox (via openshell exec --no-tty, workdir=/sandbox/work)"
  env_line=$(agent_env_token "$agent")
  if [ -n "$env_line" ]; then
    log "  injecting ${env_line%%=*} into sandbox (from host)"
    exec openshell sandbox exec --name "$sandbox" --no-tty --workdir /sandbox/work -- /usr/bin/env "$env_line" "$agent" "$@"
  else
    exec openshell sandbox exec --name "$sandbox" --no-tty --workdir /sandbox/work -- "$agent" "$@"
  fi
fi
