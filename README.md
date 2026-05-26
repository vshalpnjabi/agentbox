# agentbox

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
- [alerter](https://github.com/vjeantet/alerter) — `brew install vjeantet/tap/alerter` (for approval dialogs)
- [qrencode](https://fukuchi.org/works/qrencode/) — `brew install qrencode` (optional, for ntfy QR setup)
- Docker (or Podman / k8s / openshell VM driver) running — sandbox compute backend
- At least one supported agent on `$PATH`: `claude`, `codex`, or `opencode`

## Install

**One-liner (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/bootstrap.sh | bash
```

The bootstrap script checks the platform, installs any missing Homebrew deps (openshell, mutagen, alerter, qrencode, jq), clones the repo to `~/src/agentbox`, and runs the installer. Add to your shell rc and you're done.

**Or manually:**

```bash
git clone https://github.com/vshlpunjabi/agentbox.git ~/src/agentbox
~/src/agentbox/install.sh
```

Either way, add this to your shell config so the shim takes priority over the real agent binaries:

```bash
# zsh / bash (~/.zshrc or ~/.bashrc):
export PATH="$HOME/.local/share/agentbox/bin:$PATH"

# nushell (env.nu):
$env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/share/agentbox/bin")
```

Then open a new shell, and `claude` / `codex` / `opencode` will route through agentbox.

### Bootstrap knobs

```bash
AGENTBOX_PREFIX=~/code curl -fsSL .../bootstrap.sh | bash   # clone target (default ~/src)
AGENTBOX_YES=1         curl -fsSL .../bootstrap.sh | bash   # don't prompt before brew installs
AGENTBOX_SKIP_BREW=1   curl -fsSL .../bootstrap.sh | bash   # don't auto-install deps; just check
AGENTBOX_BRANCH=dev    curl -fsSL .../bootstrap.sh | bash   # check out a different branch
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
agentbox shell                       # interactive shell inside the sandbox
agentbox stop                        # pause sync (sandbox preserved)
agentbox pull                        # force-flush sync (sandbox -> host)
agentbox destroy                     # delete sandbox + ssh block (host state preserved)
agentbox destroy --purge             # also wipe ~/.local/share/agentbox/state/<sandbox>/

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
```

## Approval workflow

When the agent inside the sandbox attempts a network call to a host not in policy:

1. openshell proxy denies the connection (CONNECT 403).
2. agentbox watcher detects the deny in `openshell logs --tail`.
3. Watcher SIGSTOPs the agent process(es) inside the sandbox so the TUI visibly freezes.
4. A notification is shown — alerter on macOS (default), or ntfy.sh push (opt-in) to all your subscribed devices.
5. You click **Allow** or **Deny**.
   - **Allow** → watcher pushes a policy update via `openshell policy update` (hot-reload, <1s); future requests to that endpoint pass silently. SIGCONT resumes the agent. Note: the original 403 already reached the agent; tell it to retry.
   - **Deny** → watcher records the (binary, host:port) tuple in `watcher-seen.txt` so you're not asked again; SIGCONT resumes. Agent reports the failure.

The seen-list is per-sandbox and editable via `agentbox approve {list|forget|reset}`.

## Resilience

- **`claude --continue` survives sandbox loss**: state is mutagen-synced to `~/.local/share/agentbox/state/<sandbox>/`. Sandbox recreated → state synced back → continue works.
- **`agentbox destroy && claude`**: full rebuild, same policy, same session history.
- **Out-of-band container loss** (Docker crash, manual `docker rm`): next agent invocation auto-detects the Error phase, recreates the sandbox, restores state. No manual intervention.

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
