# agentbox — guidance for Claude Code sessions working on this repo

This file orients future Claude Code (or another agent) working on agentbox.
Read once before touching the code; the rules and gotchas below are bought with painful debugging.

## What this project is

`agentbox` is a single-script tool (`agentbox.sh`) that intercepts the `claude` / `codex` / `opencode`
commands and routes them through a per-workspace [openshell](https://github.com/NVIDIA/OpenShell) sandbox
with live two-way mutagen sync, persisted state, an approval watcher, and auto-synthesized credentials.

The whole tool is one bash script plus an installer. There's no daemon, no compiled binary.
All state lives in:

```
~/.local/share/agentbox/
  agentbox.sh                ← symlink to this repo's agentbox.sh (single source of truth)
  bin/{agentbox,claude,codex,opencode} → all symlink to agentbox.sh ($0 dispatch)
  originals.conf             ← paths to real agent binaries (for AGENTBOX_BYPASS)
  ntfy-topic                 ← (optional) ntfy.sh topic for push notifications
  state/<sandbox-name>/      ← per-sandbox: watcher.pid, watcher.log, watcher-seen.txt,
                                            claude/projects/* (mutagen-synced from sandbox)
```

The script is symlinked from `~/.local/share/agentbox/agentbox.sh` to this repo's `agentbox.sh`,
so edits in the repo are live immediately — no install step between edits and effect.

## When in doubt, what does `claude` actually do?

```
user types `claude` in shell
  → PATH resolves to ~/.local/share/agentbox/bin/claude (symlink to agentbox.sh)
  → bash runs agentbox.sh, $0 = "claude"
  → dispatch by $0 basename:
       - "agentbox"        → cmd_* management subcommands
       - "agentbox.sh"     → __watch (hidden, only valid first arg)
       - "claude|codex|opencode" → agent dispatch (the common case)
  → agent dispatch:
       0. load_config             reads .agentbox.toml if present (cpu/memory/image/policy)
       1. ensure_workspace_policy writes .agentbox.policy.yaml if missing
       2. sandbox_ensure          create/attach via `openshell sandbox create --name <ws>...`
       3. ssh_config_sync         writes ~/.ssh/config block from `openshell sandbox ssh-config`
       4. upload_agent_credentials uploads synthetic .credentials.json + ~/.claude.json
       5. mutagen_ensure          workspace ⇄ /sandbox/work (two-way)
       6. mutagen_state_ensure    state dir ⇄ /sandbox/.claude/projects
       7. watcher_ensure          nohup'd background watcher for approval prompts
       8. agent_ensure_installed  verifies the agent exists in the sandbox (no-op for base image)
       9. exec ssh -t openshell-<sandbox> ... <agent> "$@"
```

The deterministic sandbox name is `agentbox-<basename>-<sha256(abs(pwd))[0:8]>`. Same workspace = same sandbox.

## Hard-won rules (DO NOT IGNORE)

### 1. `openshell sandbox exec` hangs from a nohup'd background context

If you call `openshell sandbox exec` from inside the watcher's `while read line` loop (or any
nohup'd subshell), it hangs indefinitely because the `while read` pipe's stdin gets inherited
and openshell-exec waits for it to close.

**Always pipe `< /dev/null` when running `openshell sandbox exec` from any non-foreground context:**

```bash
openshell sandbox exec --name X --no-tty -- /bin/sh -c "$cmd" </dev/null >/dev/null 2>&1
```

This includes `freeze_sandbox_agents`, `unfreeze_sandbox_agents`, and any helper that runs
from the watcher's background process. Foreground agent dispatch calls don't need it.

### 2. `claude setup-token` MUST run with a real pty (not piped)

The TUI renders an ANSI animation that requires cursor positioning. Piping breaks it — the
animation re-renders every frame as raw text. Use `script(1)`:

```bash
script -q <tmpfile> claude setup-token   # captures session in <tmpfile> with TTY intact
```

Then regex-extract the token from the session transcript (strip ANSI first).

### 3. Three files must exist inside the sandbox to skip claude's first-run flow

```
/sandbox/.claude/.credentials.json    auth (claudeAiOauth block with long-lived token)
/sandbox/.claude.json                 onboarding + oauthAccount blob + per-path trust
/sandbox/.claude.json.projects["/sandbox/work"].hasTrustDialogAccepted = true
```

`CLAUDE_CODE_OAUTH_TOKEN` env var is sufficient for `claude --print` and `claude auth status`
to return loggedIn=true, but the TUI checks for the on-disk credential blob too. Without the
synthetic `.claude.json` upload, the welcome screen + login-method + per-path-trust dialogs
all fire on every new sandbox.

### 4. Renaming /sandbox to /agentbox doesn't work without building a custom image

The `base` openshell community image hardcodes `/sandbox` as the sandbox user's writable home.
`/` is owned by root inside the container. `--upload .:/agentbox/work` fails with
"mkdir: cannot create directory '/agentbox': Permission denied" because the sandbox user
can't create a sibling dir at `/`. To actually rename the home dir, you need a custom Dockerfile
that does `usermod -d /agentbox -m sandbox` and `mkdir + chown`. Reverted this change three
times; don't try again without the image work.

### 5. `--tty` vs `--no-tty` on `openshell sandbox exec`

openshell's auto-detection misses the agentbox launch context (after the exec chain through
the bash shim). Always pass the flag explicitly based on whether the shim's own stdout is a tty:

```bash
[ -t 1 ] && agb_tty_flag="--tty" || agb_tty_flag="--no-tty"
```

Forcing `--tty` when no tty exists makes the call hang. Forcing `--no-tty` when there is one
gives garbled output (claude prints DA/DCS terminal queries that never get consumed).

### 6. ssh -t for interactive TUI; openshell sandbox exec --no-tty for piped/scripted

`openshell sandbox exec --tty`'s gRPC channel mangles claude's TUI output (each byte becomes
a line). The interactive launch path goes through `ssh -t` via the openshell-managed
~/.ssh/config block instead — SSH does proper PTY allocation:

```bash
exec ssh -t "openshell-$sandbox" "<setup_prefix>cd /sandbox/work && exec $agent $quoted"
```

Where `<setup_prefix>` exports `HOME=/sandbox`, ensures `~/.local/bin/claude` symlink exists,
sets `PATH=$HOME/.local/bin:$PATH`, and injects `CLAUDE_CODE_OAUTH_TOKEN` if available.

### 7. Watcher logs MUST distinguish "saw deny, in seen-list, suppressed" from "saw nothing"

If the watcher detects a deny and finds the tuple already in seen-list, log a line saying so.
Otherwise the user wonders "why didn't I get a prompt for pypi?" and debugging is impossible.

```bash
if grep -Fxq "$key" "$seen_file"; then
  echo "[watcher] suppressed (already in seen-list): $key" >&2
  continue
fi
```

### 8. `local` keyword only works inside functions

The agent dispatch at the bottom of agentbox.sh runs as top-level script, not inside a function.
Using `local var=...` there errors with `local: can only be used in a function` AND aborts the
launch silently if the script is invoked via the shim's exec chain. Just use plain assignment
in top-level code.

### 9. Booleans accept multiple truthy values (`is_truthy` helper)

Every `AGENTBOX_*` boolean env var accepts `1`, `true`, `yes`, `on`, `y`, `t` (case-insensitive)
via the `is_truthy` helper. When adding new boolean knobs, use `is_truthy "${VAR:-}"`, never
`[ "$VAR" = "1" ]`.

## Building / testing

There's no test suite. Iteration is manual:

```bash
# Make a code change
$EDITOR agentbox.sh

# Smoke-test the shell
bash -n agentbox.sh && echo "syntax OK"

# Test in a real sandbox (in a scratch workspace)
mkdir -p /tmp/agentbox-test && cd /tmp/agentbox-test && git init -q
AGENTBOX_TTY=off claude --version
# (claude --version exits cleanly and the shim must not hang or error)
agentbox status
agentbox destroy
```

For testing the watcher / approval flow, trigger a real network deny from inside a sandbox:

```bash
openshell sandbox exec --name <sandbox> --no-tty -- /usr/bin/curl --max-time 3 https://example.com </dev/null
```

Watch `~/.local/share/agentbox/state/<sandbox>/watcher.log` for the `[watcher] denied: ...` line.

## Where to make changes

- **Approval prompts (notifications)**: `prompt_approval()` + `ntfy_prompt()` / `alerter` fallback.
- **Watcher main loop**: `cmd_watch_internal()`.
- **Sandbox lifecycle**: `sandbox_ensure()`, `cmd_destroy()`, `cmd_stop()`, `cmd_pull()`.
- **Mutagen sync**: `mutagen_ensure()` (workspace) + `mutagen_state_ensure()` (state).
- **Credential synthesis**: `upload_agent_credentials()` + `upload_claude_credentials_synthetic()`.
- **Agent launch**: end of file (top-level after the dispatch hidden-subcommand checks).
- **Policy template**: `write_default_policy()`.

When adding a new subcommand to `agentbox` itself, register it in the CLI dispatch at the bottom
(the `case "$sub" in ... esac` block right after `self_name=$(basename "$0")`).

## What NOT to do without thinking carefully

- Don't add new top-level uses of `local` (rule 8).
- Don't change the workspace mount from `/sandbox/work` (rule 4).
- Don't pipe `openshell sandbox exec` output to `tee` or anything that holds stdin (rule 1).
- Don't pipe `claude setup-token` (rule 2).
- Don't remove the `</dev/null` from existing `openshell sandbox exec` calls in the watcher.
- Don't change the deterministic sandbox-name algorithm without considering existing workspaces.
- Don't tear out the `is_truthy` helper; replace bool comparisons with it instead.

## Project history (heavily compressed)

Built collaboratively with Claude Code over many iterations. Major design decisions in commit log:

- Initial scaffolding + mutagen + per-workspace sandboxes
- ssh-based interactive launch (replaces openshell exec --tty for TUIs)
- Approval watcher with SIGSTOP freeze + macOS dialog
- Credential synthesis to bypass claude TUI's first-run prompts
- ntfy.sh opt-in for cross-device approval notifications
- `is_truthy` helper for consistent env-var booleans

Full log: `git log --oneline`.
