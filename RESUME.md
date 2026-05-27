# Resume notes

State of the project on pause. Pick this up next session.

## Release status (READ FIRST)

- **`main`** is at commit `f8c0c95`, tagged `v0.2.0`. Pushed to `origin/main`.
- **Latest release:** [v0.2.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.2.0) (2026-05-26).
- **Previous release:** [v0.1.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.1.0).
- **Install command:** `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash`.
- **`decide-endpoint-server` branch:** merged to main, still exists on origin (not deleted; `git push origin --delete decide-endpoint-server` if desired).
- **Working tree:** clean.

## What v0.2.0 shipped

23 commits on top of v0.1.0:

| Area | Feature |
|---|---|
| **decide-server** | Host-side HTTP `/decide` endpoint for openshell's forthcoming Interactive enforcement. `bin/agentbox-decide.py` Python 3 stdlib server, `__decide` handler, `agentbox decide {status,start,stop,test,logs,seen}` subcommands. Opt-in via `AGENTBOX_DECIDE_SERVER=1`. |
| **force-retry** | `AGENTBOX_FORCE_RETRY=1` auto-injects a retry prompt into the agent after Allow. Char-by-char typing defeats Claude Code's paste-detect mode. Configurable prompt/delay/submit-key. |
| **tmux wrap** | Default-on. Every TTY launch wraps in `tmux new-session -d -s <sandbox>` on a private `-L agentbox` socket. Enables focus-independent retry via send-keys, detach/reattach, status-bar showing the sandbox name. Opt out: `AGENTBOX_NO_TMUX=1`. |
| **subcommands** | `agentbox attach`, `agentbox ssh [-- cmd]`, `agentbox resize cpu\|memory N`, `agentbox sudo {enable\|disable\|status}`. |
| **always re-prompt** | Default flipped: every deny re-prompts (catches openshell policy hot-reload failures). Opt back into the old seen-list suppression with `AGENTBOX_SUPPRESS_REPEATS=1`. |
| **in-sandbox sudo** | `agentbox sudo enable` configures NOPASSWD sudo via `docker exec -u 0`. Auto-installs sudo binary on debian/alpine/fedora/rhel. |
| **install** | tmux added as a brew/apt prereq; doctor reports tmux state. Version-print bug in success line fixed. |

Full release notes: `CHANGELOG.md`.

## Known issues observed but not yet root-caused

- **`openshell policy update --add-endpoint --wait` reports success but doesn't always apply.** Real-world repro from this session: clicking Allow logs "policy hot-reloaded by user" but subsequent requests to the same `(binary, host, port)` continue to be denied. The new default-on re-prompt behavior masks this for users (they get re-prompted, can Allow again or edit the policy file), but the underlying openshell bug is real. Worth filing against the openshell-interactive-enforcement fork while we're in that codebase anyway.
- **openshell sandbox exec has no `--user` flag.** Confirmed via `--help`. Agentbox now uses `docker exec -u 0 <container-id>` directly for root operations (`agentbox sudo`). Works on Docker Desktop without host sudo. If openshell ever ships a `--user` flag, we could switch back for cleaner abstraction — minor.

## Parked next steps (in priority order)

### 1. Implement openshell hold-and-ask enforcement (in the fork)

Lives in `~/Library/CloudStorage/Dropbox/github.com/openshell-interactive-enforcement/` on branch `interactive-enforcement` (worktree of fork `vshalpnjabi/OpenShell`). Already pushed to origin:

- `docs/interactive-enforcement/DESIGN.md` — architecture for hold-and-ask
- `docs/interactive-enforcement/CLAUDE.md` — phased implementation checklist

Once that lands upstream, agentbox's decide-server can come off the `AGENTBOX_DECIDE_SERVER=1` gate and become the default approval path — and the watcher-path's "agent saw the 403, must retry" problem goes away entirely (Interactive mode holds the connection open until /decide returns).

**Outstanding agentbox-side follow-ups** (deferred until openshell upstream lands):
- HMAC auth for the wire protocol (open question 2 in DESIGN.md).
- Bind decide-server to docker-bridge IP (or Unix socket) instead of 127.0.0.1-only, so the sandbox can actually reach it (open question 1).
- Update the auto-generated `.agentbox.policy.yaml` template to emit `enforcement: interactive` blocks referencing `http://host.openshell.internal:<port>/decide`.

### 2. Investigate `openshell policy update --add-endpoint` non-application bug

When the watcher's user-Allow runs `openshell policy update --add-endpoint`, it returns 0 (and the audit log records "policy hot-reloaded by user"), but subsequent requests for the same `(binary, host, port)` continue to deny. Reproduced reliably in the openshell-interactive-enforcement workspace with curl + rust-lang.org endpoints. Repro recipe:

```
# In any workspace with deny-all-network policy:
agentbox approve reset  # clear seen-list
# inside the agent: try a denied URL, click Allow on the prompt
# audit log shows ALLOW + policy-hot-reloaded
# try the same URL again — still denied
```

Hypothesis: the rule format emitted by `--add-endpoint` doesn't match the request's normalized form (e.g., DNS-resolved IP vs hostname, or a different binary path than what triggered the deny).

### 3. Optional: delete the `decide-endpoint-server` branch from origin

Already fully merged. `git push origin --delete decide-endpoint-server` cleans it up. Not urgent.

## Other notes worth remembering on resume

- **Don't try renaming `/sandbox` → `/agentbox` again.** Reverted three times in v0.1.0 era. The base openshell image hardcodes `/sandbox` as the user home; requires a custom Dockerfile. See `CLAUDE.md` rule 4.
- **`originals.conf` is gitignored**; the live file at `~/.local/share/agentbox/originals.conf` currently points at:
  - `claude=/Users/vishalpunjabi/.local/bin/claude`
  - `codex=/opt/homebrew/bin/codex`
  - `opencode=/Users/vishalpunjabi/.opencode/bin/opencode`
- **First-attempt allow semantics still deferred** to the openshell interactive-enforcement work — agentbox currently catches *post-deny*, not *pre-deny*. The fork's hold-and-ask mode is the path to changing that. The decide-server is already wired up agentbox-side; just waiting on the upstream consumer.
- **Tool name:** `agentbox` (locked). `agentbox.com` is unavailable; .com-available shortlist if a landing page is ever needed: `agentcocoon` (.com + .io + .sh free), `hullyard` (all free, weak meaning). `agentvouch` is the best semantic fit but .com is taken.
- **`.dev` domain check was blocked** during the rename discussion (Google's RDAP returned HTTP 000). If a `.dev` is wanted later, check from a different network or use a third-party API.

## Where the code lives

- **Main worktree**: `~/Library/CloudStorage/Dropbox/github.com/agentbox/` (branch `main`, at `f8c0c95`).
- **decide-endpoint-server worktree**: `~/Library/CloudStorage/Dropbox/github.com/agentbox/.claude/worktrees/decide-endpoint-server/` (branch `decide-endpoint-server`, also at `f8c0c95` — fully merged into main). Safe to remove via `git worktree remove .claude/worktrees/decide-endpoint-server` if you don't want it around.
- **openshell fork worktree**: `~/Library/CloudStorage/Dropbox/github.com/openshell-interactive-enforcement/` (branch `interactive-enforcement` on `vshalpnjabi/OpenShell`). Has the DESIGN.md + CLAUDE.md docs; implementation hasn't started.
- **Install location**: `~/.local/share/agentbox/agentbox.sh` symlinks to `~/src/agentbox/agentbox.sh` after a clean install (NOT to the Dropbox checkout — install bootstrap clones to `~/src/agentbox`).
