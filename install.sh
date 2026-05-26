#!/usr/bin/env bash
# agentbox installer — works either as:
#
#   1) A standalone curl-pipe-bash bootstrapper (no checkout needed):
#        curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash
#
#   2) A local install from an existing checkout:
#        git clone https://github.com/vshalpnjabi/agentbox.git ~/src/agentbox
#        ~/src/agentbox/install.sh
#
# It auto-detects which mode it's in via the presence of agentbox.sh next to itself.
#
# Override knobs (env vars):
#   AGENTBOX_PREFIX=~/src        Where to clone the repo (mode 1 only).
#   AGENTBOX_REPO=https://...    Override repo URL (e.g., for a fork).
#   AGENTBOX_BRANCH=main         Branch to check out.
#   AGENTBOX_SKIP_BREW=1         Don't auto-install deps via brew; just check.
#   AGENTBOX_YES=1               Don't prompt for confirmation on dep install.

set -euo pipefail

c_blue=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_reset=$'\033[0m'
log()  { printf '%sinstall:%s %s\n' "$c_blue"   "$c_reset" "$*"; }
warn() { printf '%sinstall:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
err()  { printf '%sinstall:%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }
ok()   { printf '%sinstall:%s %s\n' "$c_green"  "$c_reset" "$*"; }

# ---- platform check ----
case "$(uname)" in
  Darwin) ;;
  Linux)  warn "Linux is not fully tested. macOS-only features (alerter notifications, ntfy.app) degrade gracefully." ;;
  *)      err "unsupported platform: $(uname). agentbox is macOS-first." ;;
esac

# ---- prompt helper (no tty = curl-pipe = default yes) ----
confirm() {
  local prompt="$1"
  [ "${AGENTBOX_YES:-0}" = "1" ] && return 0
  # Prefer /dev/tty so curl-pipe-bash still asks interactively (stdin = pipe).
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s [Y/n] ' "$prompt" > /dev/tty
    local ans
    IFS= read -r ans < /dev/tty
    case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
  fi
  return 0   # No tty: default YES for install (the curl-pipe-bash assumption)
}

# ---- detect mode ----
# We're in "local" mode IFF we were invoked as a real file (not via bash -c)
# AND the file lives next to agentbox.sh. `bash -c "$(curl ...)"` sets
# BASH_SOURCE[0] to "main" with no path, so we treat it as bootstrap.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
MODE="bootstrap"
REPO_DIR=""
if [ -n "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "main" ] && [ -f "$SCRIPT_PATH" ]; then
  if command -v realpath >/dev/null 2>&1; then
    SCRIPT_DIR=$(dirname "$(realpath "$SCRIPT_PATH")")
  else
    SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)
  fi
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/agentbox.sh" ]; then
    MODE="local"
    REPO_DIR="$SCRIPT_DIR"
  fi
fi

log "mode: $MODE"

# ---- mode 1: bootstrap (curl-pipe-bash) — fetch the repo, then re-run self ----
if [ "$MODE" = "bootstrap" ]; then
  PREFIX="${AGENTBOX_PREFIX:-$HOME/src}"
  REPO_URL="${AGENTBOX_REPO:-https://github.com/vshalpnjabi/agentbox.git}"
  BRANCH="${AGENTBOX_BRANCH:-main}"
  TARGET="$PREFIX/agentbox"

  # Deps needed to bootstrap (git, plus all runtime deps so we do it once)
  ensure_brew() {
    command -v brew >/dev/null 2>&1 && return 0
    [ "${AGENTBOX_SKIP_BREW:-0}" = "1" ] && err "Homebrew missing and AGENTBOX_SKIP_BREW=1"
    err "Homebrew not found. Install from https://brew.sh first, then re-run."
  }

  declare -a deps=(
    "git:git"
    "openshell:nvidia/openshell/openshell"
    "mutagen:mutagen-io/mutagen/mutagen"
    "alerter:vjeantet/tap/alerter"
    "qrencode:qrencode"
    "jq:jq"
  )

  missing=()
  for entry in "${deps[@]}"; do
    cmd="${entry%%:*}"; spec="${entry##*:}"
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd:$spec")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    log "missing dependencies:"
    for m in "${missing[@]}"; do printf '    %s\n' "${m%%:*}"; done
    [ "${AGENTBOX_SKIP_BREW:-0}" = "1" ] && err "AGENTBOX_SKIP_BREW=1; install the above manually and re-run."
    ensure_brew
    if confirm "Install missing deps via Homebrew now?"; then
      for m in "${missing[@]}"; do
        spec="${m##*:}"
        log "brew install $spec"
        brew install "$spec" 2>&1 | tail -3
      done
      ok "deps installed"
    else
      err "deps required; bailing"
    fi
  else
    ok "all deps already installed"
  fi

  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 && ok "Docker daemon reachable" \
      || warn "Docker installed but daemon not running. Start Docker Desktop before using agentbox."
  elif command -v podman >/dev/null 2>&1; then
    ok "podman detected (alternate compute driver)"
  else
    warn "no Docker/Podman/k8s detected. openshell needs a compute driver. Install Docker Desktop from https://docker.com"
  fi

  mkdir -p "$PREFIX"
  if [ -d "$TARGET/.git" ]; then
    log "updating existing checkout at $TARGET"
    git -C "$TARGET" fetch --quiet origin "$BRANCH"
    git -C "$TARGET" checkout --quiet "$BRANCH"
    git -C "$TARGET" pull --quiet --ff-only origin "$BRANCH"
  else
    log "cloning $REPO_URL ($BRANCH) -> $TARGET"
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$TARGET"
  fi
  ok "repo at $TARGET ($(git -C "$TARGET" rev-parse --short HEAD))"

  log "re-running install.sh from the local checkout"
  exec "$TARGET/install.sh"
fi

# ---- mode 2: local install (from existing checkout) ----
AGB_HOME="${AGB_HOME:-$HOME/.local/share/agentbox}"
AGB_BIN="$AGB_HOME/bin"
USER_BIN="$HOME/.local/bin"

log "checking runtime dependencies"
command -v openshell >/dev/null 2>&1 || warn "openshell missing — brew install nvidia/openshell/openshell"
command -v mutagen   >/dev/null 2>&1 || warn "mutagen missing — brew tap mutagen-io/mutagen && brew install mutagen"
command -v alerter   >/dev/null 2>&1 || warn "alerter missing (optional, for approval dialogs) — brew install vjeantet/tap/alerter"
command -v qrencode  >/dev/null 2>&1 || warn "qrencode missing (optional, for ntfy QR) — brew install qrencode"
command -v jq        >/dev/null 2>&1 || warn "jq missing — brew install jq"
docker info >/dev/null 2>&1 || warn "docker daemon not reachable. Start Docker Desktop before using agentbox."

log "scanning for installed agents"
mkdir -p "$AGB_HOME" "$AGB_BIN" "$USER_BIN" "$AGB_HOME/state"

# Strip $AGB_BIN from PATH for discovery so we find the REAL agent binaries
# (not our own shims, which are already first in PATH on a re-install).
CLEAN_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFx "$AGB_BIN" | tr '\n' ':' | sed 's/:$//')

: > "$AGB_HOME/originals.conf"
found=()
for agent in claude codex opencode gemini; do
  if path=$(PATH="$CLEAN_PATH" command -v "$agent" 2>/dev/null); then
    # Also skip if somehow the cleaned PATH still returns our shim (shouldn't happen)
    case "$path" in
      "$AGB_BIN"/*) continue ;;
    esac
    echo "$agent=$path" >> "$AGB_HOME/originals.conf"
    found+=("$agent")
    log "  found: $agent -> $path"
  fi
done

[ "${#found[@]}" -eq 0 ] && err "no supported agents found on \$PATH (need at least one of: claude, codex, opencode, gemini)"

log "installing shims under $AGB_BIN"
ln -sf "$REPO_DIR/agentbox.sh" "$AGB_HOME/agentbox.sh"
ln -sf "$AGB_HOME/agentbox.sh" "$AGB_BIN/agentbox"
for agent in "${found[@]}"; do
  ln -sf "$AGB_HOME/agentbox.sh" "$AGB_BIN/$agent"
done

ln -sf "$AGB_HOME/agentbox.sh" "$USER_BIN/agentbox"
chmod +x "$REPO_DIR/agentbox.sh"

ok "agentbox installed"
log "running doctor for a final health check"
echo
"$AGB_BIN/agentbox" doctor || true
echo

cat <<EOF
  Files:
    repo:          $REPO_DIR
    install dir:   $AGB_HOME
    shims (agent): $AGB_BIN
    mgmt symlink:  $USER_BIN/agentbox
    state dir:     $AGB_HOME/state

  Add this to your shell config so 'claude'/'codex'/'opencode' resolve to
  the agentbox shim instead of the real binaries:

    # zsh / bash:
    export PATH="\$HOME/.local/share/agentbox/bin:\$PATH"

    # nushell (env.nu):
    \$env.PATH = (\$env.PATH | prepend \$"(\$env.HOME)/.local/share/agentbox/bin")

  Then open a new shell and run 'agentbox help' or just 'claude' inside any workspace.

  Optional one-time setup (interactive):

    agentbox auth setup claude         # auto-authenticate claude inside sandboxes
    agentbox notify setup              # ntfy.sh push notifications (opt-in)

  Bypass agentbox for one invocation: AGENTBOX_BYPASS=1 claude

  Source + docs: https://github.com/vshalpnjabi/agentbox

EOF
