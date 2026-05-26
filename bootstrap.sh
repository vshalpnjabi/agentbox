#!/usr/bin/env bash
# agentbox bootstrap installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/bootstrap.sh | AGENTBOX_PREFIX=~/src bash
#
# What it does:
#   1. Verifies macOS / supported platform.
#   2. Installs missing dependencies via Homebrew (openshell, mutagen, alerter, qrencode, jq).
#   3. Clones the agentbox repo to $AGENTBOX_PREFIX/agentbox (default: ~/src/agentbox).
#   4. Runs the repo's install.sh which sets up shims and writes originals.conf.
#   5. Prints the PATH line to add to your shell rc.
#
# Override knobs:
#   AGENTBOX_PREFIX=~/src        Where to clone the repo.
#   AGENTBOX_REPO=https://...    Override repo URL (e.g., for a fork).
#   AGENTBOX_BRANCH=main         Branch to check out.
#   AGENTBOX_SKIP_BREW=1         Don't auto-install deps via brew; just check.
#   AGENTBOX_YES=1               Don't prompt for confirmation on dep install.

set -euo pipefail

PREFIX="${AGENTBOX_PREFIX:-$HOME/src}"
REPO_URL="${AGENTBOX_REPO:-https://github.com/vshlpunjabi/agentbox.git}"
BRANCH="${AGENTBOX_BRANCH:-main}"
TARGET="$PREFIX/agentbox"

c_blue=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_reset=$'\033[0m'
log()  { printf '%sbootstrap:%s %s\n' "$c_blue"   "$c_reset" "$*"; }
warn() { printf '%sbootstrap:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
err()  { printf '%sbootstrap:%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }
ok()   { printf '%sbootstrap:%s %s\n' "$c_green"  "$c_reset" "$*"; }

# ---- platform check ----
case "$(uname)" in
  Darwin) ;;
  Linux)  warn "Linux is not fully tested. macOS-specific features (alerter notifications, ntfy app) will degrade gracefully." ;;
  *)      err "unsupported platform: $(uname). agentbox is macOS-first." ;;
esac

# ---- prompt helper ----
confirm() {
  local prompt="$1"
  [ "${AGENTBOX_YES:-0}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    # No tty (curl-pipe-bash); default to yes
    return 0
  fi
  printf '%s [Y/n] ' "$prompt"
  local ans
  read -r ans
  case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# ---- detect and install dependencies ----
ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew detected"
    return 0
  fi
  if [ "${AGENTBOX_SKIP_BREW:-0}" = "1" ]; then
    err "Homebrew not found and AGENTBOX_SKIP_BREW=1; cannot continue"
  fi
  warn "Homebrew not found. Install from https://brew.sh first, then re-run."
  exit 1
}

# Map of: command -> brew formula spec
declare -a deps=(
  "openshell:nvidia/openshell/openshell"
  "mutagen:mutagen-io/mutagen/mutagen"
  "alerter:vjeantet/tap/alerter"
  "qrencode:qrencode"
  "jq:jq"
)

missing=()
for entry in "${deps[@]}"; do
  cmd="${entry%%:*}"
  brew_spec="${entry##*:}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd:$brew_spec")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  log "missing dependencies:"
  for m in "${missing[@]}"; do printf '    %s\n' "${m%%:*}"; done

  if [ "${AGENTBOX_SKIP_BREW:-0}" = "1" ]; then
    err "AGENTBOX_SKIP_BREW=1 set; please install the above manually and re-run."
  fi

  ensure_brew

  if confirm "Install missing deps via Homebrew now?"; then
    for m in "${missing[@]}"; do
      cmd="${m%%:*}"
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

# ---- docker / compute driver check ----
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable"
  else
    warn "Docker installed but daemon not running. Start Docker Desktop before using agentbox."
  fi
elif command -v podman >/dev/null 2>&1; then
  ok "podman detected (alternate compute driver)"
else
  warn "no Docker/Podman/k8s detected. openshell needs a compute driver. Install Docker Desktop from https://docker.com"
fi

# ---- clone or update the agentbox repo ----
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

# ---- run the repo's install.sh ----
log "running install.sh"
"$TARGET/install.sh"

ok "agentbox bootstrap complete"
cat <<EONOTE

  Add this to your shell config so 'claude'/'codex'/'opencode' resolve
  to the agentbox shim instead of the real binaries:

    # zsh / bash:
    export PATH="\$HOME/.local/share/agentbox/bin:\$PATH"

    # nushell (env.nu):
    \$env.PATH = (\$env.PATH | prepend \$"(\$env.HOME)/.local/share/agentbox/bin")

  Then open a new shell. Optional one-time setup:

    agentbox auth setup claude          # auto-authenticate claude inside sandboxes
    agentbox notify setup               # ntfy.sh push notifications (opt-in)

  Source + docs: https://github.com/vshlpunjabi/agentbox

EONOTE
