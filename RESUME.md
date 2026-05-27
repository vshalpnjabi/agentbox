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

## Known issues / resolved investigations

- **~~`openshell policy update --add-endpoint --wait` silent no-op~~** **RESOLVED.** Reproduced cleanly with a single watcher (post-`cc5a4e8` orphan fix): policy version increments, rule visible in `policy get --full`, subsequent request succeeds with `policy:allow_<host>_<port>` matched. The original "I clicked Allow but it didn't work" was 100% caused by concurrent watchers racing on the policy update (each reading v_N, writing v_N+1, last write wins). Single-watcher invariant fixes it. No upstream openshell bug.

- **openshell sandbox exec has no `--user` flag.** Confirmed via `--help`. Agentbox uses `docker exec -u 0 <container-id>` directly for root operations (`agentbox sudo`). Works on Docker Desktop without host sudo. If openshell ever ships a `--user` flag, we could switch back for cleaner abstraction — minor.

- **L4 CONNECT denial preempts the decide-server.** Today, openshell denies CONNECT at L4 immediately when a host isn't in any policy. Our decide-server is wired to consume L7 Interactive enforcement (which doesn't exist upstream yet). Net: the decide-server's L7 *trigger* is dead until openshell upstream ships `enforcement: interactive`. We've worked around this by routing L4 watcher events through the decide-server (commit `71a1bca`) so the decision pipeline gets real exercise. The "agent sees a 403 and must retry" cost is mitigated by `AGENTBOX_FORCE_RETRY=1` (auto-types `retry` after Allow). See "Custom proxy interceptor" below for the contingency plan if upstream doesn't land.

## Parked next steps (in priority order)

### 1. Implement openshell hold-and-ask enforcement (in the fork) — PRIMARY PATH

Lives in `~/Library/CloudStorage/Dropbox/github.com/openshell-interactive-enforcement/` on branch `interactive-enforcement` (worktree of fork `vshalpnjabi/OpenShell`). Already pushed to origin:

- `docs/interactive-enforcement/DESIGN.md` — architecture for hold-and-ask
- `docs/interactive-enforcement/CLAUDE.md` — phased implementation checklist

Once that lands upstream, the L7 trigger comes alive: openshell will POST request details to the decide-server, the connection holds until the user decides, agent never sees a 403 (no retry needed).

**Outstanding agentbox-side follow-ups** (deferred until openshell upstream lands):
- HMAC auth for the wire protocol (open question 2 in DESIGN.md).
- Bind decide-server to docker-bridge IP (or Unix socket) instead of 127.0.0.1-only, so the sandbox can actually reach it (open question 1).
- Update the auto-generated `.agentbox.policy.yaml` template to emit `enforcement: interactive` blocks referencing `http://host.openshell.internal:<port>/decide`.

### 2. CONTINGENCY: Custom CONNECT-proxy interceptor inside agentbox

**Only build this if option 1 stalls** (upstream Interactive enforcement isn't moving toward merge, or the fork's PR sits indefinitely). This implements interactive L4 enforcement WITHOUT upstream support, at the cost of maintaining a chunk of net code in agentbox.

**Architecture sketch:**
```
sandbox env: HTTP_PROXY=http://host.openshell.internal:NEW_PORT
                                                       │
                                                       ▼
                            ┌──────────────────────────────────────┐
                            │ agentbox-proxy (NEW, ~300 LOC)       │
                            │  - listens on host's docker-bridge   │
                            │  - intercepts every CONNECT          │
                            │  - POSTs to local decide-server      │
                            │  - on allow: TCP-forwards to         │
                            │    openshell's proxy at :3128        │
                            │  - on deny: returns HTTP 403         │
                            └──────────────────────────────────────┘
                                                       │
                                                       ▼
                            ┌──────────────────────────────────────┐
                            │ openshell proxy at 10.200.0.1:3128   │
                            │  (unchanged; policy in full-allow    │
                            │   mode for hosts agentbox-proxy lets │
                            │   through)                           │
                            └──────────────────────────────────────┘
```

**What it gives us:**
- Real interactive L4 enforcement TODAY, no upstream dependency.
- Agent NEVER sees a 403 for unknown hosts (no retry needed; the connection is held open exactly like upstream Interactive would).
- Decide-server stays the canonical decision pipeline (same as L4 watcher today; same as L7 future).

**Costs:**
- ~300 lines of Python/Go for an HTTP CONNECT proxy (TCP forwarding, TLS handshake passthrough, HTTP/1.1 + maybe HTTP/2 hooks).
- Maintenance burden: this is a security-critical net component. Test surface large.
- Throw-away the day openshell upstream ships Interactive — though decide-server stays. Just the proxy goes.
- Risk of regressions in the working L4-watcher path — would want to keep both running side-by-side during transition.

**Decision criteria for actually building it:**
- Upstream openshell shows no movement on Interactive for 3+ months from the date the PR is filed against NVIDIA/OpenShell.
- OR: user demand for "no-retry semantics" outweighs the maintenance cost.
- OR: a security-critical workflow appears where the agent SEEING a 403 (even briefly) is unacceptable (e.g., agent uses it as a signal that something is allowed/blocked and changes behavior accordingly).

**Implementation hints when the time comes:**
- Use Python 3 stdlib `socketserver` + `ssl` (same family as our existing `bin/agentbox-decide.py`).
- Run as a sibling process to the decide-server, gated by `AGENTBOX_PROXY_INTERCEPT=1` while in beta.
- Port can be deterministic per-sandbox (like decide-server's port), in the IANA dynamic range.
- Sandbox-side: inject `HTTP_PROXY` env override at agent launch (before openshell's proxy env applies).
- Be sure to handle CONNECT tunneling (90% of agent traffic is HTTPS).

### 3. Optional: delete the `decide-endpoint-server` branch from origin

Already fully merged and the branch was already deleted from origin on 2026-05-27. Local worktree at `.claude/worktrees/decide-endpoint-server/` still exists; safe to remove via `git worktree remove .claude/worktrees/decide-endpoint-server`.

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
