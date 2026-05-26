# agentbox

Per-workspace [openshell](https://docs.nvidia.com/openshell/) sandboxes for AI coding agents.

`claude`, `codex`, `opencode` (and friends) get transparently routed through an isolated sandbox per workspace folder, with live two-way file sync to the host, a deny-by-default policy YAML you can edit per workspace, and persisted session history that survives container loss.

## What it does

```
~/projects/foo $ claude
# becomes:
#   1. Sandbox `agentbox-foo-<hash>` is created (or reused) from the openshell `base` image
#   2. Workspace mounts at /sandbox/work; mutagen syncs host <-> sandbox in real time
#   3. /sandbox/.claude/projects (session history) syncs to ~/.local/share/agentbox/state/
#   4. A deny-all .agentbox.policy.yaml is written if absent; edits hot-reload
#   5. Claude runs inside the sandbox; you see its TTY as if it ran locally
```

## Requirements

- macOS or Linux
- [openshell](https://docs.nvidia.com/openshell/get-started/quickstart) (Homebrew: `brew install nvidia/openshell/openshell`)
- [mutagen](https://mutagen.io) (Homebrew: `brew tap mutagen-io/mutagen && brew install mutagen`)
- A compute driver running (Docker Desktop, Podman, k8s, or openshell's VM driver)
- At least one supported agent on `$PATH`: `claude`, `codex`, `opencode`, or `gemini`

## Install

```bash
git clone <this-repo> ~/src/agentbox
~/src/agentbox/install.sh
```

The installer detects which agents you have, creates shim symlinks, and prints the PATH lines to add to your shell config.

## One-time auth setup (claude on macOS only)

Claude Code on macOS stores OAuth tokens in the system Keychain — the on-disk `~/.claude/.credentials.json` only holds an expired/cached snapshot, and refresh tokens are bound to the host installation. To run claude inside a sandbox with persistent auth, you need a long-lived token:

```bash
claude setup-token > ~/.claude/.agentbox-oauth-token
chmod 600 ~/.claude/.agentbox-oauth-token
```

agentbox auto-detects this file and injects it as `CLAUDE_CODE_OAUTH_TOKEN` into every sandbox claude invocation. Falls back to `ANTHROPIC_API_KEY` from your env if the token file is absent. If neither is set, claude inside the sandbox will prompt for browser auth on first use (and re-auth periodically as tokens refresh).

For codex / opencode the host's `~/.codex/auth.json` and `~/.local/share/opencode/auth.json` are uploaded automatically and don't need the same dance.

## Usage

```bash
# Inside any workspace folder
claude              # auto-sandbox claude in this workspace
codex               # ditto
opencode            # ditto

# Bypass sandboxing for one invocation
AGENTBOX_BYPASS=1 claude

# Management
agentbox status            # show sandboxes + sync sessions + persisted state
agentbox name              # print sandbox name for this workspace
agentbox shell             # open an interactive shell inside the sandbox
agentbox stop              # pause syncs (sandbox stays alive)
agentbox pull              # force-flush both sync sessions
agentbox policy show       # print active policy on the running sandbox
agentbox policy edit       # edit .agentbox.policy.yaml in $EDITOR
agentbox policy reload     # push workspace policy to running sandbox (network rules hot-reload)
agentbox destroy           # delete sandbox + sync + ssh block (host state preserved)
agentbox destroy --purge   # also wipe ~/.local/share/agentbox/state/<sandbox>/
```

## Per-workspace configuration

Two files live in a workspace root, both safe to commit:

### `.agentbox.policy.yaml`

Auto-generated on first invocation. Defaults: **deny all network**, baseline filesystem only (workspace at `/sandbox/work` read-write; system paths read-only). Edit to grant access — examples are in the file header.

Network changes hot-reload via `agentbox policy reload`. Static fields (filesystem/landlock/process) require `agentbox destroy && claude` to take effect.

### `.agentbox.toml` (optional)

Per-workspace overrides:

```toml
image = "base"                # openshell community image
cpu = "1"
memory = "1Gi"
policy = "./custom.yaml"      # override the auto-generated policy
upload_credentials = false    # if true, copies ~/.claude into the sandbox at create
```

## Resilience

- **`claude --continue` across sessions** — sandbox is reused, claude's session history persists in `/sandbox/.claude/projects` (which mutagen mirrors to host).
- **`agentbox destroy && claude`** — sandbox + sync are recreated, workspace and session history are restored from the host. Same policy is reapplied.
- **Out-of-band container loss** (Docker crash, manual `docker rm`) — next agent invocation auto-detects the `Error` phase, recreates the sandbox, and restores state. No manual intervention.

## How it works (architecture sketch)

```
                          shim symlink (claude/codex/opencode)
                                        |
                                        v
                              ~/.local/share/agentbox/bin/<agent>
                              -> agentbox.sh (dispatch by $0)
                                        |
              .-----------------------+-----------------+--------------------.
              v                       v                 v                    v
        openshell sandbox       mutagen sync       mutagen sync           policy
        create/attach           workspace <->      /sandbox/.claude/      apply via
        --name <ws>             /sandbox/work      projects <->           --policy at
        --policy <yaml>         (host <-> sandbox) ~/.local/share/        create-time
        --upload .:/sandbox/work                   agentbox/state/<ws>/
              |
              v
        openshell sandbox exec --name <ws> --workdir /sandbox/work -- <agent>
```

Sandbox naming is deterministic: `agentbox-<basename>-<sha256(abs_path)[:8]>`. So every shell from the same workspace path lands in the same sandbox; different workspaces never collide.

## License

MIT
