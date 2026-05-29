# agentbox

[![release](https://img.shields.io/github/v/release/vshalpnjabi/agentbox?sort=semver)](https://github.com/vshalpnjabi/agentbox/releases/latest)

Per-workspace [openshell](https://docs.nvidia.com/openshell/) sandboxes for AI coding agents.

`claude`, `codex`, `opencode` get transparently routed through an isolated [openshell](https://github.com/NVIDIA/OpenShell) sandbox per workspace folder, with live two-way file sync to the host, persistent session history that survives sandbox loss, auto-authenticated agents (one-time host setup), and an interactive approval workflow (macOS notifications or cross-device push via [ntfy.sh](https://ntfy.sh)) for any network access that isn't pre-allowed.

## What it does

```
~/projects/foo $ claude
```

Behind the scenes:

1. Per-workspace sandbox `agentbox-foo-<sha8>` is created (or reused) from the openshell `base` image.
2. Workspace mounts at `/sandbox/work`; [mutagen](https://mutagen.io) bidirectionally syncs host ⇄ sandbox in real time.
3. `/sandbox/.claude/projects` (session history) syncs to `~/.local/share/agentbox/state/` so `claude --continue` survives sandbox loss.
4. A deny-by-default `.agentbox.policy.yaml` is auto-generated if absent (with reasonable allows for anthropic / openai / opencode / github).
5. Long-lived OAuth token + synthetic `.credentials.json` + `~/.claude.json` are uploaded so the TUI skips welcome / login / trust prompts.
6. A background watcher catches any out-of-policy network attempt, freezes the agent (SIGSTOP), and prompts you to Allow / Deny — Allow hot-reloads policy and resumes; agent retries succeed.

End-to-end: type `claude` in any folder, get a fully-authenticated, sandboxed agent with policy-gated network — no first-run friction, no per-sandbox auth, no manual policy edits for common dev hosts.

## Requirements

- macOS (primary target) or Linux
- [openshell](https://docs.nvidia.com/openshell/get-started/quickstart) — `brew install nvidia/openshell/openshell`
- [mutagen](https://mutagen.io) — `brew tap mutagen-io/mutagen && brew install mutagen`
- [tmux](https://github.com/tmux/tmux) — `brew install tmux` (default-on wrap around the agent's TTY, since v0.2.0)
- [alerter](https://github.com/vjeantet/alerter) — `brew install vjeantet/tap/alerter` (for approval dialogs)
- [qrencode](https://fukuchi.org/works/qrencode/) — `brew install qrencode` (optional, for ntfy QR setup)
- python3 (default-on decide-server uses it; comes with macOS. Set `AGENTBOX_NO_DECIDE_SERVER=1` to skip it.)
- Docker (or Podman / k8s / openshell VM driver) running — sandbox compute backend
- At least one supported agent on `$PATH`: `claude`, `codex`, or `opencode`

## Install

agentbox runs natively on **macOS** and **Linux**. On **Windows** it runs inside **WSL** — the Windows entry points (`install.ps1`, `install.bat`) bootstrap WSL and install agentbox there.

| Platform | One-liner |
|---|---|
| **macOS** | `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh \| bash` |
| **Linux** | same as macOS (alerter is replaced with zenity / notify-send fallbacks) |
| **WSL (from inside Linux)** | same as Linux |
| **Windows PowerShell** | `iwr https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.ps1 \| iex` |
| **Windows CMD** | `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.bat -o install.bat && install.bat` |

The bootstrap auto-installs missing Homebrew/apt deps (openshell, mutagen, alerter or zenity, qrencode, jq), clones the repo to `~/src/agentbox`, and runs the local installer. Add the printed PATH line to your shell rc and you're done.

**Or manually:**

```bash
git clone https://github.com/vshalpnjabi/agentbox.git ~/src/agentbox
~/src/agentbox/install.sh
```

### Platform notes

- **Linux**: alerter (macOS-only) is replaced with `zenity` (graphical Allow/Deny) or `notify-send` + a terminal prompt. Install `zenity` for the nicest UX: `sudo apt install -y zenity libnotify-bin`.
- **WSL**: works exactly like Linux from inside WSL. Docker Desktop's WSL2 integration must be enabled (Settings → Resources → WSL integration → toggle on for your distro).
- **Windows**: agentbox itself is bash-only and runs inside WSL. The Windows entry points (`install.ps1` / `install.bat`) install/configure WSL if missing and forward all agentbox commands into the WSL distro. To launch claude from a Windows terminal: `wsl bash -lc "claude"` (or open a WSL shell and use `claude` directly).

Either way, add this to your shell config so the shim takes priority over the real agent binaries:

```bash
# zsh / bash (~/.zshrc or ~/.bashrc):
export PATH="$HOME/.local/share/agentbox/bin:$PATH"

# nushell (env.nu):
$env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/share/agentbox/bin")
```

Then open a new shell, and `claude` / `codex` / `opencode` will route through agentbox.

## Uninstall

| Platform | One-liner |
|---|---|
| **macOS / Linux / WSL** | `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/uninstall.sh \| bash` |
| **Windows PowerShell**  | `iwr https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/uninstall.ps1 \| iex` |
| **Windows CMD**         | `curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/uninstall.bat -o uninstall.bat && uninstall.bat` |

Or from your local checkout:

```bash
~/src/agentbox/uninstall.sh           # interactive; asks tier-by-tier
~/src/agentbox/uninstall.sh --all     # remove everything (one summary prompt)
agentbox uninstall --yes              # non-interactive; removes the default tier (shims only)
```

Tiered removal — you pick which to remove:

| Tier | What it touches |
|---|---|
| `shims` (always) | `~/.local/share/agentbox/bin/*`, `~/.local/bin/agentbox`, `~/.local/share/agentbox/agentbox.sh` |
| `sandboxes` | Every `agentbox-*` openshell sandbox + its mutagen sync sessions |
| `ssh config` | `# agentbox:start/end` blocks in `~/.ssh/config` |
| `state` | `~/.local/share/agentbox/state/` (audit logs, watcher state, session history) |
| `tokens` | `~/.claude/.agentbox-oauth-token`, ntfy topic |
| `workspaces` (off by default) | `.agentbox.policy.yaml` + `.agentbox.toml` under `~` (you usually want to keep these — they're in version control) |

NOT touched: Homebrew deps (run `brew uninstall ...` yourself), macOS Accessibility/Notification permissions (manual), and the PATH lines you added to your shell rc (uninstall prints them; you remove).

### Bootstrap knobs

```bash
AGENTBOX_PREFIX=~/code curl -fsSL .../install.sh | bash   # clone target (default ~/src)
AGENTBOX_YES=1         curl -fsSL .../install.sh | bash   # don't prompt before brew installs
AGENTBOX_SKIP_BREW=1   curl -fsSL .../install.sh | bash   # don't auto-install deps; just check
AGENTBOX_BRANCH=dev    curl -fsSL .../install.sh | bash   # check out a different branch
```

## One-time host setup

### Claude auto-authentication (skip every browser-auth flow)

```bash
agentbox auth setup claude
```

Wraps `claude setup-token` in a pty so its TUI works, then auto-extracts and saves the long-lived token to `~/.claude/.agentbox-oauth-token`. Every future sandbox claude launch injects `CLAUDE_CODE_OAUTH_TOKEN` + synthesizes `.credentials.json` + `.claude.json` — no welcome screen, no login method prompt, no trust dialog. Same flow for `codex` / `opencode`:

```bash
agentbox auth setup codex      # runs `codex login`
agentbox auth setup opencode   # runs `opencode auth login`
agentbox auth setup all        # do all three in sequence
agentbox auth status           # show what's configured
```

### Push notifications via ntfy.sh (optional, opt-in)

By default approval prompts use [alerter](https://github.com/vjeantet/alerter) (local macOS notifications with Allow/Deny actions). For cross-device push (phone, web, desktop), opt in to [ntfy.sh](https://ntfy.sh):

```bash
agentbox notify setup           # generate random topic, print QR + open ntfy app or browser
export AGENTBOX_NTFY=1          # add to ~/.zshrc to enable; without this, alerter is used
```

ntfy delivers true two-button inline notifications on iOS / Android / Mac app / browser. After setup, every approval prompt fans out to all your subscribed devices simultaneously.

## Usage

```bash
# Inside any workspace folder
claude              # auto-sandbox claude
codex               # ditto
opencode            # ditto

# Bypass sandboxing for one invocation
AGENTBOX_BYPASS=1 claude

# Management
agentbox status                      # list sandboxes + sync sessions + state usage
agentbox name                        # print sandbox name for current workspace
agentbox shell                       # interactive shell inside the sandbox (openshell exec)
agentbox ssh [-- cmd args...]        # ssh -t into sandbox; supports one-shot commands
                                     # e.g.  agentbox ssh -- cat /etc/os-release
agentbox attach                      # reattach to this workspace's tmux session
agentbox stop                        # pause sync + kill watcher (sandbox preserved)
agentbox pull                        # force-flush sync (sandbox -> host)
agentbox destroy                     # delete sandbox + ssh block (host state preserved)
agentbox destroy --purge             # also wipe ~/.local/share/agentbox/state/<sandbox>/

# Sandbox resources (cpu / memory) — writes .agentbox.toml + optionally recreates
agentbox resize                      # show effective config
agentbox resize cpu 4 memory 4Gi     # set values for next launch
agentbox resize cpu 4 --apply        # set + destroy + auto-recreate (state preserved)

# In-sandbox NOPASSWD sudo for the agent (opt-in; stays fully contained)
agentbox sudo                        # show status (toml + env + live in-sandbox state)
agentbox sudo enable                 # write sudo=true to .agentbox.toml AND apply
agentbox sudo disable                # remove /etc/sudoers.d/agentbox + drop from toml

# Decide-server (host-side HTTP endpoint for openshell's forthcoming Interactive
# enforcement mode; opt-in via AGENTBOX_DECIDE_SERVER=1)
agentbox decide status               # running pid/port + endpoint URL
agentbox decide start                # manually start
agentbox decide stop                 # stop
agentbox decide test [host [port]]   # send a synthetic /decide POST (exercises prompt UI)
agentbox decide logs                 # tail server log
agentbox decide seen                 # show cached allow/deny decisions

# Policy management (per workspace)
agentbox policy show                 # print active policy on the running sandbox
agentbox policy edit                 # open .agentbox.policy.yaml in $EDITOR
agentbox policy reload               # push edits to running sandbox (hot-reloads network rules)
agentbox policy reset                # restore default policy + wipe approval seen-list

# Approval seen-list (tuples the watcher won't re-prompt for)
agentbox approve list                # show what's been approved/denied
agentbox approve forget pypi.org     # forget one host so it re-prompts next time
agentbox approve reset               # wipe the whole seen-list

# ntfy push notification setup
agentbox notify setup                # one-time setup (interactive)
agentbox notify status               # topic + URL + enabled-or-not
agentbox notify test                 # send a real Allow/Deny prompt and report which you clicked
agentbox notify open                 # re-open subscribe target (ntfy app or browser)
agentbox notify qr                   # re-print subscribe QR
agentbox notify clear                # remove saved topic

# Per-agent auth
agentbox auth setup <agent|all>      # interactive login + save host credential
agentbox auth status                 # tabular view of all three agents
agentbox auth clear <agent|all>      # remove host credential

# Notification appearance (macOS Alerts vs Banners)
agentbox notifications               # open System Settings -> Notifications -> Terminal
```

## Per-workspace configuration

Two files live in a workspace root, both safe to commit.

### `.agentbox.policy.yaml`

Auto-generated on first invocation. Defaults: claude/codex/opencode/github allowed; everything else denied. Edit to grant more access.

- **Network**: hot-reload via `agentbox policy reload` — no sandbox restart, just an `openshell policy update` call.
- **Filesystem / Landlock / Process**: static; require `agentbox destroy && claude` to apply (sandbox-level config is set at create time).

The default template has `include_workdir: true` + permissive read_write for typical Linux roots (`/sandbox`, `/tmp`, `/var`, `/run`, `/home`, `/root`, `/dev`) so the agent can do normal dev work inside the container without filesystem friction.

### `.agentbox.toml` (optional)

Per-workspace overrides:

```toml
image = "base"                # openshell community image (base | ollama | ...)
cpu = "1"
memory = "1Gi"
policy = "./custom.yaml"      # override the auto-generated policy file
upload_credentials = false    # unused since agentbox auto-syncs credentials
sudo = true                   # grant NOPASSWD sudo to the sandbox user (since v0.2.0)
```

The same file is what `agentbox resize` and `agentbox sudo enable` write to, so prefer those commands over hand-editing.

## Approval workflow

When the agent inside the sandbox attempts a network call to a host not in policy:

1. openshell proxy denies the connection (CONNECT 403 at L4).
2. agentbox watcher detects the deny in `openshell logs --tail`.
3. Watcher SIGSTOPs the agent process(es) inside the sandbox so the TUI visibly freezes.
4. A notification is shown — alerter on macOS (default), or ntfy.sh push (opt-in) to all your subscribed devices.
5. You click **Allow** or **Deny**.
   - **Allow** → watcher pushes a policy update via `openshell policy update`; future requests to that endpoint should pass. SIGCONT resumes the agent. Optionally, if `AGENTBOX_FORCE_RETRY=1` is set, agentbox also types `retry` into the agent's tmux session and submits — so you don't have to tell the agent to retry yourself.
   - **Deny** → SIGCONT resumes; the agent reports the failure.

Decisions are persisted in `watcher-seen.txt` (per-sandbox) for audit, but **by default v0.2.0 re-prompts on every deny** even for tuples you've decided on before (catches cases where the openshell policy hot-reload reports success but doesn't actually apply). Set `AGENTBOX_SUPPRESS_REPEATS=1` to opt back into the older "decide once, never re-prompt" mode.

The seen-list is per-sandbox and editable via `agentbox approve {list|forget|reset}`.

### Force-retry auto-inject (since v0.2.0)

`AGENTBOX_FORCE_RETRY=1` makes agentbox type a `retry` message into the agent's tmux pane after you click Allow. Char-by-char with a small per-char delay to defeat Claude Code's paste-detect / multi-line input mode. Works regardless of which terminal window has focus — `tmux send-keys` delivers to the pane directly. Overridable:

```bash
export AGENTBOX_FORCE_RETRY=1
export AGENTBOX_RETRY_PROMPT="..."           # default: "retry"
export AGENTBOX_RETRY_TYPING_DELAY=0.02      # seconds between chars
export AGENTBOX_RETRY_SUBMIT_KEY="Enter"     # try "Escape Enter" / "C-Enter" if Enter doesn't submit
```

### Decide-server (host-side HTTP endpoint for openshell's Interactive mode, opt-in)

`bin/agentbox-decide.py` (Python 3 stdlib, 127.0.0.1) runs per sandbox **by default**. It implements the wire protocol from openshell's forthcoming `interactive` enforcement mode AND serves as the unified decision pipeline for the L4 watcher path today:

- **L7 (openshell Interactive — future):** when upstream lands `enforcement: interactive`, openshell will POST request details, our server drives the prompt UI, and returns `{"decision":"allow"|"deny"}`. The connection is held open until you decide — agent sees a clean 200, no retry semantics needed.
- **L4 (watcher path — today):** the watcher detects openshell's CONNECT 403, SIGSTOPs the agent, POSTs the request to the decide-server with `source: watcher`. The decide-server prompts, updates the policy, and returns the decision. Watcher applies SIGCONT and (with `AGENTBOX_FORCE_RETRY=1`) types `retry` into the agent's TUI.

Result: **single decision pipeline** for both paths. Same prompt UI, same audit format, same seen-list. When upstream lands L7 Interactive, only the openshell config changes; the decide-server is already in production exercise.

To opt out and use the legacy v0.2.0 direct-prompt watcher path: `export AGENTBOX_NO_DECIDE_SERVER=1`.

## Resilience

- **`claude --continue` survives sandbox loss**: state is mutagen-synced to `~/.local/share/agentbox/state/<sandbox>/`. Sandbox recreated → state synced back → continue works.
- **`agentbox destroy && claude`**: full rebuild, same policy, same session history.
- **Out-of-band container loss** (Docker crash, manual `docker rm`): next agent invocation auto-detects the Error phase, recreates the sandbox, restores state. No manual intervention.

## Tuning Allow-prompt latency

When you click Allow on the approval dialog, agentbox runs `openshell policy update --wait` to make the new endpoint persistent. On stock openshell `0.0.42` that step takes ~5–10 seconds (gateway round-trip + supervisor policy reload). Three behaviors are available:

| Setting | Wait on Allow | Agent retry behavior | Notes |
|---|---|---|---|
| `AGENTBOX_SYNC_POLICY_UPDATE=1` | full (~7s) | exactly 1 (succeeds first try) | Pre-v0.4.13 behavior. Max correctness, slowest. |
| `AGENTBOX_POLICY_UPDATE_TIMEOUT=N` (default **`3`**) | up to N seconds | 1 if update lands in time, else 1–N during background reload | v0.4.14 default. Snappy + clean-retry for most updates. |
| `AGENTBOX_POLICY_UPDATE_TIMEOUT=0` | 0 (instant) | 1–N during ~7s background reload | v0.4.13 behavior. Instant feel, agent absorbs the reload internally. |

Decisions are always committed to the seen-list synchronously, so a subsequent deny for the same host/binary tuple is immediately cached as Allow and never re-prompts — even if the background update fails. If the update *does* fail and you want to retry, run `agentbox policy reset` to clear the cached decision and re-prompt next time.

Lower `AGENTBOX_POLICY_UPDATE_TIMEOUT` if Allow still feels slow on your machine; raise it (or use `AGENTBOX_SYNC_POLICY_UPDATE=1`) if you see retried connections during the background reload window. The wildcard Allow path (`Allow *.foo + apex foo`) runs both updates in parallel under the same bound.

## Environment variables

All boolean knobs accept `1` / `true` / `yes` / `on` (case-insensitive):

| Variable | Effect |
|---|---|
| `AGENTBOX_BYPASS` | Skip the shim, call the real agent binary. One-off un-sandboxed runs. |
| `AGENTBOX_NO_WATCH` | Disable the approval watcher for this invocation. |
| `AGENTBOX_NO_AGENT_AUTH` | Skip uploading host credentials into the sandbox. |
| `AGENTBOX_PERMISSIONS` | Keep claude's native permission prompts; don't auto-`--dangerously-skip-permissions`. |
| `AGENTBOX_NTFY` | Enable ntfy.sh push notifications (requires `agentbox notify setup` first). |
| `AGENTBOX_NTFY_SUBSCRIBE` | `auto` (default) / `app` / `browser` / `none` — which subscribe UX to use in `notify setup`. |
| `AGENTBOX_TTY` | `auto` (default) / `on` / `off` — force TTY mode for the agent. |
| `AGENTBOX_SYNC_TIMEOUT` | Seconds to wait for initial mutagen sync (default 120). |
| `AGB_DEFAULT_IMAGE` | Default community image. Default: `base`. |
| `AGB_DEFAULT_CPU` | Default CPU. Default: `1`. |
| `AGB_DEFAULT_MEMORY` | Default memory. Default: `1Gi`. |
| `AGENTBOX_NO_TMUX` | Disable the default-on tmux wrap around agent launches (since v0.2.0). |
| `AGENTBOX_TMUX_SOCKET` | tmux socket name for agentbox sessions. Default `agentbox`. |
| `AGENTBOX_TMUX_MOUSE` | `on` (default) / `off` — scroll-wheel scrollback in the tmux pane. |
| `AGENTBOX_TMUX_HISTORY` | Tmux history-limit. Default `10000`. |
| `AGENTBOX_TMUX_STATUS_LEFT` | Custom tmux `status-left` format string. |
| `AGENTBOX_TMUX_STATUS_OFF` | Hide the tmux status bar. |
| `AGENTBOX_FORCE_RETRY` | Auto-inject a `retry` prompt into the agent after Allow (since v0.2.0). |
| `AGENTBOX_RETRY_PROMPT` | Text to inject. Default `retry`. |
| `AGENTBOX_RETRY_DELAY` | Pre-inject focus-settle (keystroke fallback only; tmux path skips). |
| `AGENTBOX_RETRY_TYPING_DELAY` | Per-char delay during typing. Default `0.02`. |
| `AGENTBOX_RETRY_SUBMIT_DELAY` | Pause after typing before sending submit key. Default `0.15`. |
| `AGENTBOX_RETRY_SUBMIT_KEY` | Submit key sequence. Default `Enter`. Try `"Escape Enter"` / `"C-Enter"` / `"none"` if Enter doesn't submit. |
| `AGENTBOX_SUDO` | Configure NOPASSWD sudo inside the sandbox on next launch (since v0.2.0). |
| `AGENTBOX_NO_DECIDE_SERVER` | **Opt OUT** of the default-on decide-server. With this set, the watcher uses its legacy direct-prompt path (v0.2.0 behavior). Without this, the watcher routes its L4-deny decisions through the local decide-server so the same code handles both L4 (today) and L7 (future openshell Interactive). |
| `AGENTBOX_SUPPRESS_REPEATS` | Re-enable the older "decide once, never re-prompt" suppression (v0.2.0 default is always re-prompt). |
| `AGENTBOX_POLICY_UPDATE_TIMEOUT` | Max seconds to wait for `openshell policy update` to confirm policy active before replying Allow to the agent. Default **`3`** (since v0.4.14). Set `0` for instant reply (pure async, v0.4.13 behavior); set higher to wait longer for the clean-retry guarantee. See [Tuning Allow-prompt latency](#tuning-allow-prompt-latency) below. |
| `AGENTBOX_SYNC_POLICY_UPDATE` | Force the v0.4.12 pre-bounded-wait behavior: block fully on `openshell policy update --wait`, ignore `AGENTBOX_POLICY_UPDATE_TIMEOUT`. Pre-v0.4.13 correctness at the cost of ~7s/Allow on stock openshell. |
| `AGENTBOX_INTERACTIVE_POLICY` | **Opt IN** to writing the `interactive_gate` block into the default policy template (since v0.4.10; was default-on before). Only useful if you're running the openshell `interactive-enforcement` fork — stock 0.0.42 fails to parse the fork's `enforcement: { mode: ... }` map. |
| `AGENTBOX_TMUX_DRAG_SELECT` | **Opt IN** to tmux's native click+drag selection (since v0.4.12; default off). Off by default because tmux's `MouseDrag1Pane` binding enters copy-mode on the slightest mouse motion during a click, which Ghostty et al. surface as "highlighting on mouse move." Scroll-wheel works regardless of this knob. |

## How it works (architecture sketch)

```
                shim symlink (claude | codex | opencode)
                                 |
                                 v
                  ~/.local/share/agentbox/bin/<agent>
                  -> agentbox.sh (dispatch by $0 basename)
                                 |
   .-----------+-----------+-----+-----+-----------+--------.
   v           v           v           v           v        v
sandbox    mutagen      mutagen     watcher    credential   ssh -t (TTY)
create     sync         sync        (deny     synthesizer   openshell-<name>
or        workspace    .claude/    detection  + uploader)   "cd /sandbox/work
attach    <-> /sandbox  projects   + prompt   .credentials   && exec <agent>"
--name <ws> /work       (state)    + policy   .claude.json
--policy                            update    (skip onboarding)
<yaml>
   |
   v
agent runs inside sandbox at /sandbox/work with HOME=/sandbox
```

Sandbox naming is deterministic: `agentbox-<basename>-<sha256(abs_path)[:8]>`. Every shell from the same workspace path hits the same sandbox; different workspaces never collide.

## Acknowledgments

- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) — the sandbox runtime
- [mutagen](https://mutagen.io) — bidirectional file sync
- [alerter](https://github.com/vjeantet/alerter) — macOS notifications with action buttons
- [ntfy.sh](https://ntfy.sh) — cross-device push notifications

## License

MIT
