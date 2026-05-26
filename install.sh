#!/usr/bin/env bash
# agentbox installer: wires this repo's agentbox.sh into ~/.local/share/agentbox/,
# detects installed agents (claude/codex/opencode/gemini), creates shim symlinks,
# checks deps, and prints the PATH lines you need to add to your shell.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd -P)
AGB_HOME="${AGB_HOME:-$HOME/.local/share/agentbox}"
AGB_BIN="$AGB_HOME/bin"
USER_BIN="$HOME/.local/bin"

log()  { printf '\033[36minstall:\033[0m %s\n' "$*"; }
warn() { printf '\033[33minstall:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31minstall:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- dep checks ----
log "checking dependencies"
command -v openshell >/dev/null || err "openshell not found. Install: brew install nvidia/openshell/openshell"
command -v mutagen   >/dev/null || err "mutagen not found. Install: brew tap mutagen-io/mutagen && brew install mutagen"
command -v docker    >/dev/null || warn "docker CLI not found; the openshell gateway needs a compute driver (docker/podman/k8s/vm)"
docker info >/dev/null 2>&1 || warn "docker daemon not reachable. Start Docker Desktop (or your driver) before using agentbox."

# ---- agent detection ----
log "scanning for installed agents"
mkdir -p "$AGB_HOME" "$AGB_BIN" "$USER_BIN" "$AGB_HOME/state"
: > "$AGB_HOME/originals.conf"

found=()
for agent in claude codex opencode gemini; do
  if path=$(command -v "$agent" 2>/dev/null); then
    # Don't record the agentbox shim itself if it already shadows the agent.
    case "$path" in
      "$AGB_BIN"/*) continue ;;
    esac
    echo "$agent=$path" >> "$AGB_HOME/originals.conf"
    found+=("$agent")
    log "  found: $agent -> $path"
  fi
done

[ "${#found[@]}" -eq 0 ] && err "no supported agents found on \$PATH (need at least one of: claude, codex, opencode, gemini)"

# ---- symlinks ----
log "installing shims under $AGB_BIN"
ln -sf "$REPO_DIR/agentbox.sh" "$AGB_HOME/agentbox.sh"
ln -sf "$AGB_HOME/agentbox.sh" "$AGB_BIN/agentbox"
for agent in "${found[@]}"; do
  ln -sf "$AGB_HOME/agentbox.sh" "$AGB_BIN/$agent"
done

# Also expose the management command via the user's existing ~/.local/bin (no PATH change needed)
ln -sf "$AGB_HOME/agentbox.sh" "$USER_BIN/agentbox"

chmod +x "$REPO_DIR/agentbox.sh"

# ---- PATH hint ----
cat <<EOF

  agentbox installed.

  Files:
    repo:          $REPO_DIR
    install dir:   $AGB_HOME
    shims (agent): $AGB_BIN
    mgmt symlink:  $USER_BIN/agentbox
    state dir:     $AGB_HOME/state

  Next step — prepend the shim dir to your shell's PATH so 'claude'/'codex'/'opencode'
  resolve to agentbox instead of the real binaries:

    # zsh (~/.zshrc):
    export PATH="\$HOME/.local/share/agentbox/bin:\$PATH"

    # bash (~/.bashrc):
    export PATH="\$HOME/.local/share/agentbox/bin:\$PATH"

    # fish (~/.config/fish/config.fish):
    set -gx PATH \$HOME/.local/share/agentbox/bin \$PATH

    # nushell (env.nu):
    \$env.PATH = (\$env.PATH | prepend \$"(\$env.HOME)/.local/share/agentbox/bin")

  Then open a new shell and run 'agentbox help' or just 'claude' inside any workspace.
  To call the real binaries without sandboxing, set AGENTBOX_BYPASS=1.
EOF
