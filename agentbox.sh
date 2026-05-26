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
  # include_workdir: true auto-adds /sandbox/work to read_write.
  # openshell adds baseline paths (/usr /lib /etc /var/log read-only; /sandbox /tmp read-write)
  # but NOT the /dev and /proc pseudo-files that most runtimes need — list those explicitly.
  # Anything not listed is inaccessible (Landlock-enforced).
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /etc
    - /proc
    - /dev/urandom
    # - /opt/some-shared-data
  read_write:
    - /sandbox
    - /tmp
    - /dev/null
    # - /scratch

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
      - { host: statsig.anthropic.com, port: 443 }
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

upload_claude_credentials() {
  # Seed sandbox claude with host OAuth token so the agent is auto-authenticated.
  # /sandbox is the sandbox user's home, so /sandbox/.claude/.credentials.json is
  # what claude looks for. Idempotent: safe to call on every invocation; re-uploads
  # in case the host token was refreshed.
  local sandbox="$1"
  local src="$HOME/.claude/.credentials.json"
  [ -f "$src" ] || return 0
  [ "${AGENTBOX_NO_CLAUDE_AUTH:-0}" = "1" ] && return 0

  openshell sandbox exec --name "$sandbox" --no-tty -- mkdir -p /sandbox/.claude >/dev/null 2>&1 || true
  if openshell sandbox upload "$sandbox" "$src" /sandbox/.claude/ >/dev/null 2>&1; then
    openshell sandbox exec --name "$sandbox" --no-tty -- chmod 600 /sandbox/.claude/.credentials.json >/dev/null 2>&1 || true
    log "synced host claude credentials into sandbox (~/.claude/.credentials.json)"
  else
    warn "credential upload failed; claude inside sandbox will require browser auth"
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
  log "stopping mutagen sync for $name (sandbox + state preserved)"
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
    *)
      err "usage: agentbox policy {show|reload|edit} [NAME]"
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
  agentbox destroy [NAME]      Delete sandbox + ssh block (host state PRESERVED)
  agentbox destroy --purge [N] Also wipe ~/.local/share/agentbox/state/<sandbox>/

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
    destroy) cmd_destroy "$@" ;;
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

# Always seed claude credentials (set AGENTBOX_NO_CLAUDE_AUTH=1 to opt out)
upload_claude_credentials "$sandbox"

# Default claude to --dangerously-skip-permissions when running inside an agentbox sandbox
# (the sandbox itself enforces policy; permission prompts become redundant friction).
# Opt out per-invocation with AGENTBOX_PERMISSIONS=on, or by passing the flag yourself.
if [ "$agent" = "claude" ] && [ "${AGENTBOX_PERMISSIONS:-off}" != "on" ]; then
  has_skip=0
  for a in "$@"; do
    case "$a" in --dangerously-skip-permissions) has_skip=1; break ;; esac
  done
  if [ "$has_skip" -eq 0 ]; then
    set -- --dangerously-skip-permissions "$@"
  fi
fi

ssh_config_sync "$sandbox"
mutagen_ensure "$sandbox" "$PWD"
mutagen_state_ensure "$sandbox"
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
  exec ssh -t "$ssh_host" "cd /sandbox/work && exec $agent$quoted"
else
  log "launching $agent in $sandbox (via openshell exec --no-tty, workdir=/sandbox/work)"
  exec openshell sandbox exec --name "$sandbox" --no-tty --workdir /sandbox/work -- "$agent" "$@"
fi
