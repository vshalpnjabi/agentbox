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
#   AGENTBOX_PREFIX=~/src                Where to clone the repo (mode 1 only).
#   AGENTBOX_REPO=https://...            Override repo URL (e.g., for a fork).
#   AGENTBOX_BRANCH=main                 Branch to check out.
#   AGENTBOX_SKIP_BREW=1                 Don't auto-install deps via brew; just check.
#   AGENTBOX_YES=1                       Don't prompt for confirmation on dep install.
#
#   AGENTBOX_INTERACTIVE_OPENSHELL        Tri-state knob for the openshell install:
#       unset / empty                       Don't touch openshell (default; agentbox
#                                           uses whatever stock openshell you have).
#       1 / true / yes                      Build openshell from source from the
#                                           vshalpnjabi/OpenShell interactive-enforcement
#                                           branch and replace the cached supervisor binary
#                                           so the fork's L7 held-connection prompt path
#                                           works out of the box.
#       0 / false / no                      Revert any previous fork install: move the
#                                           fork-built openshell + gateway aside as
#                                           .fork-bak (preserved, not deleted), destroy
#                                           existing sandboxes (asks unless
#                                           AGENTBOX_YES=1), nuke the cached supervisor
#                                           (gateway re-pulls supervisor:dev), restart
#                                           the stock daemon. No-op if no fork binaries
#                                           are present.
#   AGENTBOX_OPENSHELL_REPO=…              Override the fork URL (default:
#                                          https://github.com/vshalpnjabi/OpenShell.git).
#   AGENTBOX_OPENSHELL_BRANCH=…            Override the fork branch (default:
#                                          1-interactive-enforcement/vshalpnjabi).
#   AGENTBOX_OPENSHELL_PREFIX=~/src        Where to clone the fork (default ~/src/openshell-fork).

set -euo pipefail

c_blue=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_reset=$'\033[0m'
log()  { printf '%sinstall:%s %s\n' "$c_blue"   "$c_reset" "$*"; }
warn() { printf '%sinstall:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
err()  { printf '%sinstall:%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }
ok()   { printf '%sinstall:%s %s\n' "$c_green"  "$c_reset" "$*"; }

# ---- helper: build openshell from the interactive-enforcement fork ----
#
# Opt-in via AGENTBOX_INTERACTIVE_OPENSHELL=1. Builds openshell-cli,
# openshell-server (gateway), and openshell-sandbox (supervisor binary)
# from the fork, then overwrites the cached supervisor in
# ~/.local/share/openshell/docker-supervisor/sha256-*/openshell-sandbox.
#
# After running this, existing sandboxes still use the OLD supervisor
# from inside the running container — they must be destroyed and
# recreated to pick up the new one. The function prints a reminder.
build_openshell_interactive() {
  local repo branch prefix target
  repo="${AGENTBOX_OPENSHELL_REPO:-https://github.com/vshalpnjabi/OpenShell.git}"
  branch="${AGENTBOX_OPENSHELL_BRANCH:-1-interactive-enforcement/vshalpnjabi}"
  prefix="${AGENTBOX_OPENSHELL_PREFIX:-$HOME/src}"
  target="$prefix/openshell-fork"

  log "=== building openshell interactive-enforcement fork (opt-in) ==="

  # ---- platform-specific build deps ----
  local missing_build=()
  command -v cargo >/dev/null 2>&1 || missing_build+=(rust)
  command -v git   >/dev/null 2>&1 || missing_build+=(git)
  case "$(uname)" in
    Darwin)
      # macOS needs z3 from brew + the include path injected for bindgen
      command -v brew >/dev/null 2>&1 || err "brew is required on macOS to install z3"
      brew list z3 >/dev/null 2>&1 || missing_build+=(z3)
      ;;
    Linux)
      # Linux needs libz3-dev (apt) or equivalent. Don't auto-install — just check.
      if ! dpkg -s libz3-dev >/dev/null 2>&1 \
        && ! pkg-config --exists z3 2>/dev/null; then
        missing_build+=(libz3-dev)
      fi
      ;;
  esac
  if [ "${#missing_build[@]}" -gt 0 ]; then
    case "$(uname)" in
      Darwin)
        warn "missing build deps: ${missing_build[*]}"
        if confirm "Install via Homebrew?"; then
          for m in "${missing_build[@]}"; do
            case "$m" in
              rust) brew install rust 2>&1 | tail -3 ;;
              z3)   brew install z3   2>&1 | tail -3 ;;
              git)  brew install git  2>&1 | tail -3 ;;
            esac
          done
        else
          err "deps required for openshell build; bailing"
        fi
        ;;
      Linux)
        warn "missing build deps: ${missing_build[*]}"
        warn "  sudo apt-get install -y build-essential pkg-config clang libz3-dev git"
        warn "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        err "install the above, source \$HOME/.cargo/env, then re-run with AGENTBOX_INTERACTIVE_OPENSHELL=1"
        ;;
    esac
  fi
  command -v cargo >/dev/null 2>&1 || . "$HOME/.cargo/env" 2>/dev/null || true
  command -v cargo >/dev/null 2>&1 || err "cargo not on PATH; restart your shell or 'source \$HOME/.cargo/env'"

  # ---- z3 include hint on macOS ----
  if [ "$(uname)" = "Darwin" ]; then
    local z3pfx
    z3pfx=$(brew --prefix z3 2>/dev/null || echo "/opt/homebrew/opt/z3")
    export BINDGEN_EXTRA_CLANG_ARGS="-I${z3pfx}/include ${BINDGEN_EXTRA_CLANG_ARGS:-}"
    export LIBRARY_PATH="${z3pfx}/lib:${LIBRARY_PATH:-}"
  fi

  # ---- fetch + build ----
  mkdir -p "$prefix"
  if [ -d "$target/.git" ]; then
    log "updating $target"
    git -C "$target" fetch --quiet origin "$branch" || \
      err "fetch failed; check repo $repo branch $branch"
    git -C "$target" checkout -B "$branch" "origin/$branch" 2>&1 | tail -3
  else
    log "cloning $repo branch $branch -> $target"
    git clone --branch "$branch" "$repo" "$target" 2>&1 | tail -3
  fi
  local head_sha
  head_sha=$(git -C "$target" rev-parse --short HEAD)
  log "openshell head: $head_sha"

  log "building openshell-cli, openshell-server, openshell-sandbox (release; ~3-8 min first time)"
  ( cd "$target" && cargo build --release \
      -p openshell-cli -p openshell-server -p openshell-sandbox ) || \
    err "openshell build failed"

  # ---- install CLI + gateway to ~/.cargo/bin ----
  log "installing openshell + openshell-gateway to \$HOME/.cargo/bin"
  ( cd "$target" && cargo install --path crates/openshell-cli    --bin openshell         --offline --force ) 2>&1 | tail -2 || \
    err "cargo install openshell-cli failed"
  ( cd "$target" && cargo install --path crates/openshell-server --bin openshell-gateway --offline --force ) 2>&1 | tail -2 || \
    err "cargo install openshell-gateway failed"

  # ---- overwrite cached supervisor (created by the gateway on first run) ----
  local cache="$HOME/.local/share/openshell/docker-supervisor"
  if compgen -G "$cache/sha256-*/openshell-sandbox" > /dev/null; then
    log "overwriting cached supervisor binary in $cache/sha256-*/openshell-sandbox"
    for f in "$cache"/sha256-*/openshell-sandbox; do
      cp -f "$target/target/release/openshell-sandbox" "$f"
    done
    ok "supervisor cache refreshed (new sha: $(sha256sum < "$target/target/release/openshell-sandbox" 2>/dev/null | awk '{print substr($1,1,12)}'))"
  else
    log "no cached supervisor yet — will be created on first sandbox launch"
    log "after the first sandbox runs (and the gateway pulls supervisor:dev), re-run:"
    log "    cp $target/target/release/openshell-sandbox $cache/sha256-*/openshell-sandbox"
    log "    agentbox destroy <each-sandbox>   # so containers pick up the new binary"
  fi

  ok "openshell fork installed (head $head_sha)"
  echo
  warn "Existing sandboxes are running the OLD supervisor. To pick up the new"
  warn "code, destroy and recreate each sandbox:"
  warn "    openshell sandbox list"
  warn "    agentbox destroy <name>"
  warn "    # then 'claude' in that workspace will recreate"
}

# ---- helper: revert openshell back to the stock (brew/distro) install ----
#
# Inverse of build_openshell_interactive: move the fork-built binaries aside
# so PATH lookup hits the stock ones again, destroy any sandboxes that are
# running the fork's supervisor, blow away the supervisor cache (gateway
# will re-pull ghcr.io/nvidia/openshell/supervisor:dev), and restart the
# stock daemon on macOS. Refuses if there's nothing to revert.
revert_openshell_interactive() {
  log "=== reverting fork-built openshell back to stock ==="

  local fork_cli="$HOME/.cargo/bin/openshell"
  local fork_gw="$HOME/.cargo/bin/openshell-gateway"
  if [ ! -f "$fork_cli" ] && [ ! -f "$fork_gw" ]; then
    warn "no fork-built openshell binaries found in \$HOME/.cargo/bin —"
    warn "nothing to revert. If stock openshell already on PATH, you're done."
    return 0
  fi

  # Move the fork binaries aside so PATH falls through to stock. Don't
  # delete outright — keep them as .fork-bak in case the user wants to
  # flip back without rebuilding.
  if [ -f "$fork_cli" ]; then
    mv -f "$fork_cli" "${fork_cli}.fork-bak"
    log "moved fork CLI to ${fork_cli}.fork-bak"
  fi
  if [ -f "$fork_gw" ]; then
    mv -f "$fork_gw" "${fork_gw}.fork-bak"
    log "moved fork gateway to ${fork_gw}.fork-bak"
  fi

  # Destroy existing sandboxes (they have the fork's supervisor binary
  # baked into their container layer, so new policy decisions would use
  # old code if we leave them running).
  local sandboxes=""
  if command -v openshell >/dev/null 2>&1; then
    sandboxes=$(openshell sandbox list 2>/dev/null | awk 'NR>1 && $1 ~ /^agentbox-/ {print $1}' || true)
  fi
  if [ -n "$sandboxes" ]; then
    log "agentbox-managed sandboxes that will be destroyed:"
    printf '    %s\n' $sandboxes
    if confirm "Destroy these sandboxes now?"; then
      for sb in $sandboxes; do
        if [ -x "$HOME/.local/share/agentbox/bin/agentbox" ]; then
          "$HOME/.local/share/agentbox/bin/agentbox" destroy "$sb" 2>&1 | tail -1
        else
          openshell sandbox delete "$sb" 2>&1 | tail -1
        fi
      done
    else
      warn "skipped sandbox destroy; you can run agentbox destroy <name> manually later"
    fi
  fi

  # Nuke the supervisor cache so the gateway re-extracts from the
  # published image on the next sandbox launch.
  local cache="$HOME/.local/share/openshell/docker-supervisor"
  if [ -d "$cache" ]; then
    log "removing cached supervisor binaries at $cache"
    rm -rf "$cache"
  fi

  # Stop any running gateway so the next start picks up the stock binary.
  case "$(uname)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        log "restarting brew openshell service"
        brew services stop openshell 2>&1 | tail -1 || true
        sleep 1
        brew services start openshell 2>&1 | tail -1 || \
          warn "brew services start openshell failed; run it manually"
      else
        warn "brew not on PATH; start the stock daemon manually"
      fi
      ;;
    Linux)
      log "stopping any running openshell-gateway"
      pkill -f openshell-gateway 2>/dev/null || true
      warn "Restart your distro's openshell service manually if you have one"
      ;;
  esac

  # rehash so subsequent `openshell` lookups find the stock binary
  hash -r 2>/dev/null || true

  ok "revert complete"
  echo
  log "verify with:"
  log "    which openshell           # should NOT be \$HOME/.cargo/bin/openshell"
  log "    openshell --version       # should match your stock install (e.g. brew 0.0.42)"
  log
  log "fork binaries are preserved at:"
  log "    ${fork_cli}.fork-bak"
  log "    ${fork_gw}.fork-bak"
  log "Remove them with 'rm \$HOME/.cargo/bin/openshell*.fork-bak' if you want them gone."
}

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

# ---- AGENTBOX_INTERACTIVE_OPENSHELL=0 — early-intercept revert path ----
# Tri-state semantics on this var:
#   1/true/yes  → build & install fork (runs later, after agentbox install)
#   0/false/no  → revert any previous fork install and EXIT (no agentbox
#                 reinstall needed for revert)
#   unset/other → don't touch openshell at all (default)
case "${AGENTBOX_INTERACTIVE_OPENSHELL:-}" in
  0|false|no|off)
    revert_openshell_interactive
    exit 0
    ;;
esac

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
    "tmux:tmux"
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
command -v tmux      >/dev/null 2>&1 || warn "tmux missing (default agent wrap; AGENTBOX_NO_TMUX=1 to skip) — brew install tmux"
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

installed_version=$("$AGB_BIN/agentbox" version 2>/dev/null || echo "")
ok "agentbox installed (${installed_version:-version unknown})"

# ---- optional: build openshell from the interactive-enforcement fork ----
# Gated by AGENTBOX_INTERACTIVE_OPENSHELL=1 so the standard install path stays
# fast (no Rust toolchain or 5-minute build for users who just want the L4
# watcher prompt fallback).
if [ "${AGENTBOX_INTERACTIVE_OPENSHELL:-0}" = "1" ] || \
   [ "${AGENTBOX_INTERACTIVE_OPENSHELL:-0}" = "true" ] || \
   [ "${AGENTBOX_INTERACTIVE_OPENSHELL:-0}" = "yes" ]; then
  echo
  build_openshell_interactive
fi

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

  Held-connection prompts (no 403-then-retry, first request is authoritative):
  Re-run the installer with the fork-build flag to install the interactive
  openshell stack alongside agentbox:

    AGENTBOX_INTERACTIVE_OPENSHELL=1 \\
      curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash

  This builds openshell-cli, openshell-server, and openshell-sandbox from the
  vshalpnjabi/OpenShell 1-interactive-enforcement branch and overwrites the
  cached supervisor binary. After that, every new workspace's sandbox uses the
  L7 held-connection prompt path by default (opt out per-workspace with
  AGENTBOX_NO_INTERACTIVE_POLICY=1).

  Revert back to stock openshell anytime (moves fork binaries aside, destroys
  sandboxes, restarts the brew/distro daemon):

    AGENTBOX_INTERACTIVE_OPENSHELL=0 \\
      curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash

  Bypass agentbox for one invocation: AGENTBOX_BYPASS=1 claude

  Source + docs: https://github.com/vshalpnjabi/agentbox

EOF
