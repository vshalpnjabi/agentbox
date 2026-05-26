#!/usr/bin/env bash
# agentbox - per-workspace openshell sandboxes for AI coding agents
# Invoked as `agentbox` for management, or via symlinks (claude, codex, opencode) to launch an agent inside the workspace sandbox.

set -euo pipefail

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
# TODO: hold-and-ask enforcement mode. Today the watcher reacts AFTER the
# proxy has 403'd the request, so the agent must be told to retry. A clean
# fix requires extending openshell's proxy with a third enforcement mode
# (e.g., "interactive") that holds the connection open while consulting
# an external decision endpoint. This file's prompt_approval would then
# serve that endpoint via a unix socket or HTTP. Deferred per user.
# Background process that tails openshell logs for NET:OPEN DENIED events and
# prompts the user (osascript display dialog) on the first occurrence of each
# (binary, host:port) tuple. Approval adds the endpoint to the workspace policy
# (hot-reloaded); decisions are remembered per-sandbox so the user is not
# prompted again for the same tuple.

watcher_state_dir() { echo "$AGB_STATE_ROOT/$1"; }
watcher_pid_file()  { echo "$(watcher_state_dir "$1")/watcher.pid"; }
watcher_log_file()  { echo "$(watcher_state_dir "$1")/watcher.log"; }
watcher_seen_file() { echo "$(watcher_state_dir "$1")/watcher-seen.txt"; }

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
  if [ "${AGENTBOX_NO_WATCH:-0}" = "1" ]; then
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

  # Clean up stale pid file if process died without removing it
  local pf
  pf=$(watcher_pid_file "$sandbox")
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
  local pf
  pf=$(watcher_pid_file "$sandbox")
  if [ -f "$pf" ]; then
    local pid
    pid=$(cat "$pf" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pf"
  fi
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
  local message="(sandbox: ${sandbox})"

  if command -v alerter >/dev/null 2>&1; then
    # Single action ("Allow") + the close button relabeled as "Deny" gives two
    # side-by-side buttons instead of a dropdown.
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
      Allow)   echo "Allow" ;;
      @CLOSED) echo "Deny" ;;
      *)       echo "" ;;
    esac
    return 0
  fi

  # Fallback: osascript display alert
  local response
  response=$(osascript 2>/dev/null <<APPLESCRIPT
display alert "${title}" message "${subtitle}\n${message}" as informational buttons {"Deny", "Allow"} default button "Allow"
APPLESCRIPT
)
  case "$response" in
    *Allow*) echo "Allow" ;;
    *Deny*)  echo "Deny" ;;
    *)       echo "" ;;
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
      [[ "$line" =~ NET:OPEN.*DENIED ]] || continue
      # Match: <binary>(<pid>) -> <host>:<port>
      if [[ "$line" =~ ([/A-Za-z0-9._-]+)\(([0-9]+)\)[[:space:]]*-\>[[:space:]]*([A-Za-z0-9.-]+):([0-9]+) ]]; then
        local binary="${BASH_REMATCH[1]}"
        local pid="${BASH_REMATCH[2]}"
        local host="${BASH_REMATCH[3]}"
        local port="${BASH_REMATCH[4]}"
        local key="${binary}|${host}|${port}"

        if grep -Fxq "$key" "$seen_file"; then
          echo "[watcher] suppressed (already in seen-list): $key" >&2
          continue
        fi
        echo "$key" >> "$seen_file"

        echo "[watcher] denied: $binary($pid) -> $host:$port — freezing + prompting" >&2

        # Freeze the offender PID and all top-level agent processes inside the
        # sandbox so the TUI visibly pauses until the user decides.
        freeze_sandbox_agents "$sandbox" "$pid"

        local response
        response=$(prompt_approval "$sandbox" "$host" "$port" "$binary")
        echo "[watcher] user response: [$response]" >&2

        if [[ "$response" == *"Allow"* ]]; then
          if openshell policy update "$sandbox" \
              --add-endpoint "${host}:${port}" \
              --binary "$binary" \
              --wait >/dev/null 2>&1; then
            echo "[watcher] approved: $host:$port for $binary (policy hot-reloaded)" >&2
            # Nudge: the agent already saw the 403 before approval. Until openshell
            # gets a hold-and-ask enforcement mode (deferred — see TODO), the user
            # has to tell the agent to retry the failed action.
            osascript -e "display notification \"$host:$port allowed. Tell agent to retry.\" with title \"agentbox\"" 2>/dev/null || true
          else
            echo "[watcher] approval failed: openshell policy update returned non-zero" >&2
          fi
        else
          echo "[watcher] denied by user: $host:$port for $binary (won't prompt again)" >&2
        fi

        unfreeze_sandbox_agents "$sandbox" "$pid"
        echo "[watcher] unfroze agents in $sandbox" >&2
      fi
    done

    # Reconnect after brief pause
    sleep 2
  done
}

load_config() {
  AGB_IMAGE="$DEFAULT_IMAGE"
  AGB_CPU="$DEFAULT_CPU"
  AGB_MEMORY="$DEFAULT_MEMORY"
  AGB_POLICY=""
  AGB_UPLOAD_CREDS="false"
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
    esac
  done < .agentbox.toml
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
  # Seed sandbox with the host's auth file for the given agent so it's
  # auto-authenticated (no browser/device-code flow inside the sandbox).
  # Idempotent: re-uploads on every invocation so a host-refreshed token stays current.
  local sandbox="$1" agent="$2"
  [ "${AGENTBOX_NO_AGENT_AUTH:-0}" = "1" ] && return 0

  local mapping src dest dest_dir
  mapping=$(agent_auth_mapping "$agent") || return 0
  [ -z "$mapping" ] && return 0
  src="${mapping%%::*}"
  dest="${mapping##*::}"
  [ -f "$src" ] || return 0
  dest_dir=$(dirname "$dest")

  openshell sandbox exec --name "$sandbox" --no-tty -- mkdir -p "$dest_dir" >/dev/null 2>&1 || true
  if openshell sandbox upload "$sandbox" "$src" "$dest" >/dev/null 2>&1; then
    openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 "$dest" >/dev/null 2>&1 || true
    log "synced host $agent credentials into sandbox ($dest)"
  else
    warn "$agent credential upload failed; agent inside sandbox will require interactive auth"
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
  mutagen sync terminate "$name" >/dev/null 2>&1 || true
  mutagen sync terminate "${name}-state" >/dev/null 2>&1 || true
}

cmd_destroy() {
  local purge=0
  local name=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -z "$name" ] && name=$(workspace_sandbox_name)
  if [ "$purge" -eq 1 ]; then
    log "destroying $name + purging host state ($AGB_STATE_ROOT/$name)"
  else
    log "destroying $name (sandbox + sync + ssh block; host state preserved at $AGB_STATE_ROOT/$name)"
  fi
  watcher_stop "$name"
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
  if [ "$purge" -eq 1 ]; then
    rm -rf "$AGB_STATE_ROOT/$name"
  fi
}

cmd_pull() {
  local name="${1:-$(workspace_sandbox_name)}"
  log "flushing mutagen sync $name (workspace + state)"
  mutagen sync flush "$name" 2>/dev/null || true
  mutagen sync flush "${name}-state" 2>/dev/null || true
}

cmd_shell() {
  local name="${1:-$(workspace_sandbox_name)}"
  exec openshell sandbox exec --name "$name" --tty --workdir /sandbox/work -- /bin/sh -lc 'exec ${SHELL:-/bin/bash} -l'
}

cmd_auth() {
  # One-time setup of a long-lived claude OAuth token. Runs the host's real
  # claude (bypassing the agentbox shim) so setup-token's interactive flow
  # works against your host's keychain auth, then saves the resulting token
  # to ~/.claude/.agentbox-oauth-token. All future agentbox sandbox claude
  # launches auto-inject this as CLAUDE_CODE_OAUTH_TOKEN — no re-auth.
  local sub="${1:-setup}"
  [ "$#" -gt 0 ] && shift
  local tok_file="$HOME/.claude/.agentbox-oauth-token"

  case "$sub" in
    setup)
      local real_claude
      real_claude=$(real_binary "claude")
      [ -z "$real_claude" ] && err "no real claude binary recorded in $AGB_ORIGINALS (run install.sh)"
      [ -x "$real_claude" ] || err "claude binary not executable at $real_claude"

      mkdir -p "$(dirname "$tok_file")"
      log "running '$real_claude setup-token' on host (interactive)..."
      log "follow the prompts; the token will be saved to $tok_file"
      echo >&2

      # setup-token's URL/instruction text goes to stderr (visible); token
      # to stdout. `tee` captures stdout to the file while still echoing.
      if "$real_claude" setup-token | tee "$tok_file"; then
        # Strip whitespace and re-write to be safe
        if [ -s "$tok_file" ]; then
          # Keep only the last non-empty line (the token), tidy whitespace
          local cleaned
          cleaned=$(grep -E "." "$tok_file" | tail -1 | tr -d "[:space:]")
          if [ -n "$cleaned" ]; then
            printf '%s\n' "$cleaned" > "$tok_file"
            chmod 600 "$tok_file"
            log "saved long-lived token to $tok_file (mode 600, ${#cleaned} chars)"
            log "future agentbox sandbox claude launches will auto-inject CLAUDE_CODE_OAUTH_TOKEN"
          else
            warn "no token captured (setup-token returned empty); retry or save manually"
            rm -f "$tok_file"
          fi
        else
          warn "token file is empty — setup-token may have aborted"
          rm -f "$tok_file"
        fi
      else
        rm -f "$tok_file"
        err "claude setup-token failed"
      fi
      ;;
    status)
      if [ -f "$tok_file" ]; then
        local sz; sz=$(wc -c < "$tok_file" | tr -d " ")
        echo "long-lived token: $tok_file ($sz bytes, $(stat -f "%Sm" "$tok_file" 2>/dev/null))"
      else
        echo "long-lived token: NOT SET   (run: agentbox auth setup)"
      fi
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "ANTHROPIC_API_KEY: set in env (${#ANTHROPIC_API_KEY} chars)"
      else
        echo "ANTHROPIC_API_KEY: not set in env"
      fi
      ;;
    clear|remove)
      if [ -f "$tok_file" ]; then
        rm -f "$tok_file"
        log "removed $tok_file"
      else
        echo "(already cleared)"
      fi
      ;;
    *)
      err "usage: agentbox auth {setup|status|clear}"
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
  # Manage the watcher seen-list — the set of (binary, host, port) tuples the
  # user has already responded to. Entries here suppress re-prompts. Use this
  # to "forget" past denials/approvals so the watcher will ask again.
  local sub="${1:-list}"
  [ "$#" -gt 0 ] && shift
  local name="${1:-$(workspace_sandbox_name)}"
  local seen_file="$AGB_STATE_ROOT/$name/watcher-seen.txt"
  case "$sub" in
    list)
      if [ ! -f "$seen_file" ]; then
        echo "(no seen-list for $name)"
        return 0
      fi
      printf '%-50s  %s\n' "BINARY" "HOST:PORT"
      awk -F'|' '{printf "%-50s  %s:%s\n", $1, $2, $3}' "$seen_file"
      ;;
    forget)
      local pattern="${1:-}"
      [ -z "$pattern" ] && err "usage: agentbox approve forget <host-or-pattern> [NAME]"
      [ -f "$seen_file" ] || { echo "(no seen-list)"; return 0; }
      local before after
      before=$(wc -l < "$seen_file" | tr -d ' ')
      grep -v "$pattern" "$seen_file" > "$seen_file.tmp" 2>/dev/null || true
      mv "$seen_file.tmp" "$seen_file"
      after=$(wc -l < "$seen_file" | tr -d ' ')
      log "removed $((before-after)) entries matching '$pattern' (was $before, now $after)"
      ;;
    reset|clear)
      if [ -f "$seen_file" ]; then
        local n; n=$(wc -l < "$seen_file" | tr -d ' ')
        : > "$seen_file"
        log "cleared seen-list ($n entries removed)"
      else
        echo "(already empty)"
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
      # Rewrite .agentbox.policy.yaml from the deny-all+defaults template, wipe
      # the watcher seen-list, and hot-reload network rules on the running sandbox
      # (if any). Static fields take effect on next `claude` (destroy + recreate
      # is implied if you want a fully fresh sandbox).
      log "resetting .agentbox.policy.yaml in $PWD to default template"
      write_default_policy "$WORKSPACE_POLICY_FILE"
      local state_dir
      state_dir="$AGB_STATE_ROOT/$name"
      if [ -f "$state_dir/watcher-seen.txt" ]; then
        log "clearing watcher seen-list ($state_dir/watcher-seen.txt)"
        : > "$state_dir/watcher-seen.txt"
      fi
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
  cat >&2 <<'EOF'
agentbox - per-workspace openshell sandboxes for AI coding agents

Management:
  agentbox status              List managed sandboxes, sync sessions, persisted state
  agentbox name                Print sandbox name for current workspace
  agentbox stop [NAME]         Pause workspace + state sync (sandbox preserved)
  agentbox pull [NAME]         Force-flush both sync sessions (workspace + state)
  agentbox shell [NAME]        Open interactive shell in sandbox
  agentbox policy show [NAME]  Print active policy on sandbox
  agentbox policy edit [NAME]  Edit .agentbox.policy.yaml in $EDITOR
  agentbox policy reload [N]   Push workspace policy to running sandbox
  agentbox policy reset [N]    Restore default policy + wipe approval seen-list

Approval seen-list (the set of (binary, host:port) tuples the watcher
won't re-prompt for):
  agentbox approve list [N]              Show seen-list for this workspace
  agentbox approve forget <pattern> [N]  Remove matching entries (re-prompts next time)
  agentbox approve reset [N]             Clear the entire seen-list

Notification appearance (macOS):
  agentbox notifications                 Open System Settings → Notifications →
                                         Terminal. Set "Notification style" to
                                         "Alerts" for persistent banner-style
                                         approval prompts with action buttons.

Claude long-lived auth (one-time host setup so sandboxes auto-authenticate):
  agentbox auth setup                    Run `claude setup-token` and save to
                                         ~/.claude/.agentbox-oauth-token
  agentbox auth status                   Show whether the token is configured
  agentbox auth clear                    Remove the saved token
  agentbox destroy [NAME]      Delete sandbox + ssh block (host state PRESERVED)
  agentbox destroy --purge [N] Also wipe ~/.local/share/agentbox/state/<sandbox>/

Approval prompts (macOS):
  When an agent inside the sandbox hits a network deny (host:port not in
  policy), a background watcher SIGSTOPs the agent process(es) and pops a
  macOS dialog asking Allow/Deny — the TUI visibly pauses until you decide.
  Allow → `openshell policy update` hot-reloads the rule, agent resumes
  (the request that triggered the prompt still 403'd; retry succeeds).
  Deny → agent resumes and sees the 403. The (binary, host, port) is kept
  in ~/.local/share/agentbox/state/<sandbox>/watcher-seen.txt so you're
  not asked again for the same tuple. Opt out with AGENTBOX_NO_WATCH=1.

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
EOF
}

# Dispatch
# Hidden subcommand: the approval watcher background process. Invoked by
# watcher_ensure via `nohup "$AGB_ROOT/agentbox.sh" __watch <sandbox>`, where
# $0 is the .sh file (not the agentbox symlink), so this needs to fire before
# any $0-based dispatch.
if [ "${1:-}" = "__watch" ]; then
  shift
  cmd_watch_internal "$@"
  exit 0
fi

self_name=$(basename "$0")

# Inside the sandbox, the shim shouldn't recurse. Just exec real binary.
if inside_sandbox && [ "$self_name" != "agentbox" ]; then
  exec "$self_name" "$@"  # PATH inside sandbox has the agents at standard locations
fi

# Explicit bypass
if [ "${AGENTBOX_BYPASS:-0}" = "1" ] && [ "$self_name" != "agentbox" ]; then
  real=$(real_binary "$self_name")
  [ -z "$real" ] && err "no real binary recorded for $self_name in $AGB_ORIGINALS"
  exec "$real" "$@"
fi

# Management CLI
if [ "$self_name" = "agentbox" ]; then
  sub="${1:-help}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    status)  cmd_status "$@" ;;
    name)    cmd_name ;;
    stop)    cmd_stop "$@" ;;
    pull)    cmd_pull "$@" ;;
    shell)   cmd_shell "$@" ;;
    policy)  cmd_policy "$@" ;;
    approve)       cmd_approve "$@" ;;
    notifications) cmd_notifications "$@" ;;
    auth)          cmd_auth "$@" ;;
    destroy) cmd_destroy "$@" ;;
    __watch) cmd_watch_internal "$@" ;;
    help|-h|--help) cmd_help ;;
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
if [ -n "$agb_skip_flag" ] && [ "${AGENTBOX_PERMISSIONS:-off}" != "on" ]; then
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
  log "launching $agent in $sandbox (via ssh -t, workdir=/sandbox/work)"
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
  exec ssh -t "$ssh_host" "${setup_prefix}${env_prefix}cd /sandbox/work && exec $agent$quoted"
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
