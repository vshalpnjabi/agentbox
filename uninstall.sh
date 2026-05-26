#!/usr/bin/env bash
# agentbox uninstaller — tiered removal so users can do partial or full uninstall.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/uninstall.sh | bash
#   ~/src/agentbox/uninstall.sh           # interactive, asks per-tier
#   ~/src/agentbox/uninstall.sh --all     # remove everything (still asks for one final confirmation)
#   ~/src/agentbox/uninstall.sh --yes     # non-interactive; remove default tier (shims + install dir)
#
# Tiers (each gets its own prompt unless --yes):
#   1. shims + install dir       (always; you're uninstalling, after all)
#   2. sandboxes + sync sessions (destroy every agentbox-* openshell sandbox + mutagen session)
#   3. ssh config blocks         (remove "# agentbox:start/end" markers from ~/.ssh/config)
#   4. host state                (~/.local/share/agentbox/state — watcher logs, audit, projects)
#   5. saved tokens              (~/.claude/.agentbox-oauth-token + ~/.local/share/agentbox/ntfy-topic)
#   6. workspace files           (.agentbox.policy.yaml + .agentbox.toml in your workspaces — OFF by default)
#
# NOT removed (untouched by uninstall):
#   - Homebrew dependencies (openshell, mutagen, alerter, qrencode, jq) — `brew uninstall` manually if you want
#   - macOS Accessibility / Notification permissions — System Settings, manual
#   - PATH lines you added to ~/.zshrc / nushell env.nu — uninstall prints them, you remove
#   - The agentbox git checkout itself (you cloned it; you delete it)

set -euo pipefail

ALL=0; YES=0; WORKSPACES=0
for arg in "$@"; do
  case "$arg" in
    --all)        ALL=1 ;;
    --yes|-y)     YES=1 ;;
    --workspaces) WORKSPACES=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \\{0,1\\}//'
      exit 0 ;;
    *) echo "unknown arg: $arg (use --help)" >&2; exit 2 ;;
  esac
done

c_blue=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_reset=$'\033[0m'
log()  { printf '%suninstall:%s %s\n' "$c_blue"   "$c_reset" "$*"; }
warn() { printf '%suninstall:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
ok()   { printf '%suninstall:%s %s\n' "$c_green"  "$c_reset" "$*"; }
err()  { printf '%suninstall:%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  [ "$YES" -eq 1 ] && return 0
  # Prefer /dev/tty so curl-pipe-bash still works interactively (stdin = pipe).
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s [y/N] ' "$prompt" > /dev/tty
    local ans
    IFS= read -r ans < /dev/tty
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
  return 1   # No tty at all: default NO for safety on uninstall
}

AGB_HOME="${AGB_HOME:-$HOME/.local/share/agentbox}"
AGB_BIN="$AGB_HOME/bin"
USER_BIN="$HOME/.local/bin"
SSH_CONFIG="$HOME/.ssh/config"

# ---- Final summary confirmation ----
echo
echo "agentbox uninstall plan:"
echo "  ✓ shims          $AGB_BIN/* + $USER_BIN/agentbox"
echo "  ✓ install dir    $AGB_HOME/{agentbox.sh,originals.conf}"

if [ "$ALL" -eq 1 ] || confirm "Also destroy all agentbox-* sandboxes + mutagen sync sessions?"; then
  REMOVE_SANDBOXES=1
  echo "  ✓ sandboxes      all agentbox-* in openshell + their mutagen sessions"
else REMOVE_SANDBOXES=0; fi

if [ "$ALL" -eq 1 ] || confirm "Also remove agentbox blocks from ~/.ssh/config?"; then
  REMOVE_SSH=1
  echo "  ✓ ssh config     # agentbox:start/end blocks in $SSH_CONFIG"
else REMOVE_SSH=0; fi

if [ "$ALL" -eq 1 ] || confirm "Also wipe host state ($AGB_HOME/state — audit logs, watcher state, sandbox-side session history)?"; then
  REMOVE_STATE=1
  echo "  ✓ state          $AGB_HOME/state"
else REMOVE_STATE=0; fi

if [ "$ALL" -eq 1 ] || confirm "Also remove saved agent tokens (~/.claude/.agentbox-oauth-token, ntfy topic)?"; then
  REMOVE_TOKENS=1
  echo "  ✓ tokens         ~/.claude/.agentbox-oauth-token + $AGB_HOME/ntfy-topic"
else REMOVE_TOKENS=0; fi

if [ "$WORKSPACES" -eq 1 ] || { [ "$ALL" -eq 1 ] && confirm "DANGEROUS: scan ~ for workspace files (.agentbox.policy.yaml, .agentbox.toml) and remove them? (these are usually in git; you probably DON'T want this)"; }; then
  REMOVE_WORKSPACES=1
  echo "  ⚠ workspace      .agentbox.policy.yaml + .agentbox.toml under \$HOME"
else REMOVE_WORKSPACES=0; fi

echo
if [ "$YES" -ne 1 ]; then
  if ! confirm "Proceed with the above?"; then
    log "aborted"
    exit 0
  fi
fi

# ---- 1. Sandboxes (do this BEFORE removing the script so we have agentbox available) ----
if [ "$REMOVE_SANDBOXES" -eq 1 ]; then
  log "destroying agentbox-* sandboxes"
  openshell sandbox list 2>/dev/null | awk '/^agentbox-/{print $1}' | while read -r name; do
    [ -z "$name" ] && continue
    # Strip ANSI codes from name
    clean=$(printf '%s' "$name" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g')
    log "  delete $clean"
    openshell sandbox delete "$clean" </dev/null >/dev/null 2>&1 || true
    mutagen sync terminate "$clean" >/dev/null 2>&1 || true
    mutagen sync terminate "${clean}-state" >/dev/null 2>&1 || true
  done

  log "killing any leftover watcher processes"
  pkill -9 -f "agentbox.sh __watch" 2>/dev/null || true
fi

# ---- 2. SSH config blocks ----
if [ "$REMOVE_SSH" -eq 1 ] && [ -f "$SSH_CONFIG" ]; then
  log "cleaning agentbox blocks from $SSH_CONFIG"
  awk '
    /^# agentbox:start / { skip=1; next }
    /^# agentbox:end /   { skip=0; next }
    !skip                { print }
  ' "$SSH_CONFIG" > "$SSH_CONFIG.tmp"
  mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG" 2>/dev/null || true
fi

# ---- 3. State ----
if [ "$REMOVE_STATE" -eq 1 ] && [ -d "$AGB_HOME/state" ]; then
  log "removing host state ($AGB_HOME/state)"
  rm -rf "$AGB_HOME/state"
fi

# ---- 4. Tokens ----
if [ "$REMOVE_TOKENS" -eq 1 ]; then
  log "removing saved tokens"
  rm -f "$HOME/.claude/.agentbox-oauth-token"
  rm -f "$AGB_HOME/ntfy-topic"
fi

# ---- 5. Workspace files (opt-in, dangerous) ----
if [ "$REMOVE_WORKSPACES" -eq 1 ]; then
  log "scanning ~ for .agentbox.policy.yaml and .agentbox.toml (this can take a minute)..."
  find "$HOME" -type f \( -name ".agentbox.policy.yaml" -o -name ".agentbox.toml" \) 2>/dev/null | while read -r f; do
    log "  rm $f"
    rm -f "$f"
  done
fi

# ---- 6. Shims (always; this is the core "uninstall" action) ----
log "removing shims under $AGB_BIN"
if [ -d "$AGB_BIN" ]; then
  for f in "$AGB_BIN"/*; do
    [ -e "$f" ] || continue
    log "  rm $f"
    rm -f "$f"
  done
  rmdir "$AGB_BIN" 2>/dev/null || true
fi

# Mgmt symlink in ~/.local/bin
[ -L "$USER_BIN/agentbox" ] && { rm -f "$USER_BIN/agentbox"; log "  rm $USER_BIN/agentbox"; }

# Install dir core files
rm -f "$AGB_HOME/agentbox.sh"
rm -f "$AGB_HOME/originals.conf"

# Try to remove the dir itself if it's empty (won't if state/tokens were kept)
rmdir "$AGB_HOME" 2>/dev/null && log "  rmdir $AGB_HOME (empty)" || true

ok "agentbox uninstalled"

echo
cat <<EOF
  Still on disk (manual cleanup if you want):
    - Homebrew deps:   brew uninstall nvidia/openshell/openshell mutagen alerter qrencode
    - PATH line(s) you added to your shell rc:
        zsh / bash:     remove the 'export PATH="\$HOME/.local/share/agentbox/bin:\$PATH"' line
        nushell env.nu: remove the line prepending agentbox/bin to \$env.PATH
    - The agentbox git checkout (if you cloned it):    rm -rf ~/src/agentbox

EOF
