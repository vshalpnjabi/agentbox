# Resume notes

State of the project on pause. Pick this up next session.

## Where we are

- **Version shipped:** `v0.1.0` (tag `v0.1.0`, commit `60da39d`). Working tree clean, pushed to `origin/main`.
- **Tool name:** `agentbox` (locked). Considered renaming because `agentbox.com` isn't available; decided rename cost (~30 file edits + re-tag + new release) isn't worth it pre-landing-page. If/when a landing page is needed, the .com-available shortlist that was vetted via Verisign whois is: `agentcocoon` (.com + .io + .sh all free), `hullyard` (all free, weak meaning). Best semantic fit with .io only: `agentvouch`.
- **Distribution surfaces working:**
  - `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash` (macOS/Linux/WSL)
  - PowerShell + CMD installers that bootstrap into WSL on Windows
  - `agentbox doctor` runs at end of install
  - `agentbox uninstall` (tiered: shims → sandboxes → ssh config → state → tokens)
- **Auth status:** synthetic `.credentials.json` + `~/.claude.json` upload is working for `claude`. `codex` and `opencode` go through `agent_auth_mapping()` and per-agent install/auth helpers.
- **Notification backends:** macOS `alerter` (dropdown UX, not side-by-side buttons — accepted that limitation), Linux `zenity`/`notify-send`/`/dev/tty` fallback, ntfy.sh as opt-in via `AGENTBOX_NTFY=1|true|yes|on`.

## Parked next steps (in priority order)

### 1. ✅ Decision-endpoint HTTP server inside agentbox — landed on branch `decide-endpoint-server`

Host-side endpoint matching `docs/interactive-enforcement/DESIGN.md` from the openshell fork.

**What shipped:**
- `bin/agentbox-decide.py` — Python 3 stdlib HTTP server. Binds 127.0.0.1 only, POST `/decide` → handler subprocess → JSON response.
- `cmd_decide_handler_internal` + `__decide` hidden subcommand in `agentbox.sh` — reads request JSON on stdin, hits cache (`decide-seen.txt`), otherwise drives `prompt_approval`, returns response JSON.
- `decide_server_ensure` / `decide_server_stop` lifecycle (parallel to the watcher's), deterministic port from sandbox-hash, pid/port/log files in the state dir.
- Hooked into the agent dispatch (after `watcher_ensure`) and into `cmd_destroy` / `cmd_stop`.
- Management surface: `agentbox decide {status,start,stop,test,logs,seen}`.
- Gated behind `AGENTBOX_DECIDE_SERVER=1` — default off until openshell Interactive mode actually exists upstream. The existing log-tail watcher stays the always-on path.
- Doctor row + help text + `CLAUDE.md` rule 10 documenting the architecture.

**Outstanding follow-ups (deferred until openshell upstream lands):**
- HMAC auth for the wire protocol (open question 2 in DESIGN.md).
- Bind to docker-bridge IP (or unix socket) instead of 127.0.0.1-only so the sandbox can actually reach the endpoint (open question 1).
- Update `.agentbox.policy.yaml` template to emit the `enforcement: interactive` block referencing `http://host.openshell.internal:<port>/decide` once openshell parses it.

### 2. Implement openshell hold-and-ask enforcement (in the fork)

Lives in `/Users/vishalpunjabi/Library/CloudStorage/Dropbox/github.com/openshell-interactive-enforcement/` on branch `interactive-enforcement` (worktree of fork `vshalpnjabi/OpenShell`). Already pushed:
- `docs/interactive-enforcement/DESIGN.md` — architecture for hold-and-ask
- `docs/interactive-enforcement/CLAUDE.md` — phased implementation checklist

Plan was to pick this up in a **separate Claude session** in that worktree.

## Other notes worth remembering on resume

- **Don't try renaming `/sandbox` → `/agentbox` again.** Reverted three times. The base openshell image hardcodes `/sandbox` as the user home; requires a custom Dockerfile. See `CLAUDE.md` rule 4.
- **`originals.conf` is gitignored**; the live file at `~/.local/share/agentbox/originals.conf` currently points at:
  - `claude=/Users/vishalpunjabi/.local/bin/claude`
  - `codex=/opt/homebrew/bin/codex`
  - `opencode=/Users/vishalpunjabi/.opencode/bin/opencode`
- **First-attempt allow semantics deferred** to the openshell interactive-enforcement work — agentbox currently catches *post-deny*, not *pre-deny*. The fork's hold-and-ask mode is the path to changing that.
- **`.dev` domain check was blocked** from this network (Google's RDAP returned HTTP 000). If a `.dev` is wanted later, check from a different network or use a third-party API.
