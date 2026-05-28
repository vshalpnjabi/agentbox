# Changelog

All notable changes to agentbox.

## [v0.4.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.4.0) — 2026-05-28

Headline: **openshell interactive enforcement is wired end-to-end**. With the openshell fork from `vshalpnjabi/OpenShell` branch `1-interactive-enforcement/vshalpnjabi`, agentbox now supports held-connection prompts on the agent's *first* outbound request to a gated host — no 403-then-retry round-trip, the agent's first attempt is authoritative. New install flag builds and installs the fork in a single curl-pipe-bash. Bearer-token auth between openshell ↔ decide-server. Per-sandbox secret auto-generated, persisted in state dir, emitted into the policy YAML. Plus: two main-side `approve` integer-comparison bugs fixed as a side effect.

### Headline features

- **L7 held-connection prompts via the openshell interactive-enforcement fork** (`44b9cc5`, `2c404e3`, `137f346`, `ef32942`). When the workspace policy contains an `enforcement.mode: interactive` block (default-on now, opt out per-workspace with `AGENTBOX_NO_INTERACTIVE_POLICY=1`), the openshell gateway holds the agent's TCP connection while POSTing a JSON decision request to the host-side decide-server. agentbox runs `prompt_approval` (ntfy / alerter / osascript / zenity / TTY), returns `{"decision":"allow"|"deny"}`, the gateway releases the held connection accordingly. The agent's first HTTP attempt completes with the decided outcome — no retry needed. End-to-end verified at 204 ms in `docs/baseline-vs-branch-confidence-tests.md`. Falls back gracefully to the L4 watcher path against stock openshell (interactive_gate is silently downgraded to plain enforce).

- **Bearer-token auth between openshell ↔ decide-server** (`9f2881a`). Upstream's `1-interactive-enforcement/vshalpnjabi` branch now signs every `/decide` POST with `Authorization: Bearer <secret>` and expects the matching secret in the policy YAML's `secret:` field. agentbox auto-generates a 32-byte hex secret per sandbox at `<state>/decide-secret.txt` (mode 600) on first sandbox creation, emits it into the policy YAML, loads it into the python decide-server, and threads it through the L4 watcher's own POSTs. `agentbox-decide.py` uses `hmac.compare_digest` for constant-time validation. Wrong / missing bearer returns HTTP 401 with `{"decision":"deny","reason":"invalid bearer token"}` — openshell treats any non-2xx as an error and applies `fallback: deny`, so unauthorized requests get clean denies without leaking timing info.

- **`AGENTBOX_INTERACTIVE_OPENSHELL=1` builds the fork during install** (`43b9b70`, consolidated in `6046112`). One-shot:
  ```
  AGENTBOX_INTERACTIVE_OPENSHELL=1 \
    curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash
  ```
  Clones the openshell fork (`vshalpnjabi/OpenShell` branch `1-interactive-enforcement/vshalpnjabi`), runs `cargo build --release` for openshell-cli, openshell-server, openshell-sandbox, installs the CLI + gateway binaries to `$HOME/.cargo/bin`, and overwrites the cached supervisor at `~/.local/share/openshell/docker-supervisor/sha256-*/openshell-sandbox` so containers extract the new binary. macOS: ensures `brew install z3 rust` + injects `BINDGEN_EXTRA_CLANG_ARGS` so z3-sys finds z3.h. Linux: prints the apt + rustup commands and bails (won't sudo blindly). Knobs: `AGENTBOX_OPENSHELL_REPO`, `AGENTBOX_OPENSHELL_BRANCH`, `AGENTBOX_OPENSHELL_PREFIX`.

- **`AGENTBOX_INTERACTIVE_OPENSHELL=0` reverts the fork build to stock** (`6046112`). Symmetric inverse — moves the fork-built binaries to `.fork-bak` (preserved, not deleted), destroys agentbox-managed sandboxes (asks unless `AGENTBOX_YES=1`), nukes the supervisor cache, and restarts the brew openshell service on macOS (or kills the gateway + reminds you on Linux). Top-level early intercept — doesn't reinstall agentbox, just reverts openshell. No-op if no fork binaries are present.

### Decide-server improvements

- **Full openshell wire-protocol parsing** (`44b9cc5`). All 11 fields the gateway emits (`schema_version`, `request_id`, `sandbox_name`, `binary`, `pid`, `host`, `port`, `method`, `path`, `protocol`, `policy_name`) parsed in `cmd_decide_handler_internal`. Validation gates: schema version mismatch → 401, sandbox-name mismatch → 401, missing required fields → 400. PROMPT audit log lines now include method + path + protocol + policy_name + pid so reviewers can see what the agent was about to do.

- **`ThreadingHTTPServer`** (`7e8ebfc`). Replaces single-threaded `HTTPServer`. The old server's accept loop stalled while a handler was waiting on user input (ntfy long-poll), starving health probes and parallel /decide POSTs. With threading, each request runs in its own thread, `daemon_threads = True` so shutdown doesn't block on in-flight prompts.

- **Configurable bind via `AGENTBOX_DECIDE_BIND`** (`44b9cc5`). Default `127.0.0.1`; set to `0.0.0.0` when the openshell gateway runs inside a container and reaches the host via `host.openshell.internal`. `agentbox decide status` shows the active bind + the sandbox-reachable endpoint URL.

- **Lifecycle hygiene** (`7e8ebfc`). `decide_server_ensure` now health-probes the tracked pid via the bound port; if alive but unresponsive (e.g., wedged on a stale connection), SIGTERM → SIGKILL → restart. `decide_server_stop` escalates SIGTERM → SIGKILL after 1 s of grace. Prevents the "pid alive, port listening, connections time out" failure mode.

- **`agentbox decide test` auto-ensures the server** (`a9aeec8`). Previously errored "decide-server not running — run 'agentbox decide start' or launch an agent". Now silently starts the server before sending the test POST, since the only reason to invoke `decide test` is to exercise the endpoint.

### Policy template

- **Default-on `interactive_gate` block emitted by `write_default_policy`** (`ef32942`). Demo target is `*.example.com` so the policy is at least valid out of the box; users edit the YAML to change hosts (the YAML is the single source of truth — no parallel env-based list). Block uses the doc-prescribed shape (`protocol: rest` + `access: full` + `deny_rules: [{method:"*", path:"**"}]`) plus the per-sandbox `secret:`. Opt out per-workspace with `AGENTBOX_NO_INTERACTIVE_POLICY=1`.

- **`ssh` command auto-ensures watcher + decide-server** (`dd46f41`). `agentbox ssh <sandbox>` previously skipped the prompt infrastructure entirely; if the watcher had died (e.g., across a Mac sleep cycle) you'd see no prompt when running a network command from your SSH session. Now both ensures fire idempotently before exec'ing ssh.

- **Wildcard `Allow` now grants apex + wildcard** (`ed04028`). openshell's wildcard semantics match subdomains only, not the apex. Clicking Allow on a banner about `github.com` previously added `*.github.com` to the policy, which silently kept `github.com` itself denied. Now AllowWildcard adds BOTH endpoints in one shot (wildcard for the zone, exact host for the apex).

### Bug fixes

- **`approve list` / `approve reset` integer-comparison crash** (`46de860`). Previously: `auto_count=$(grep -c ... || echo 0)`. When `grep -c` finds zero matches it prints `0` AND exits 1, so `|| echo 0` runs and appends a second `0` — producing the multi-line value `"0\n0"` that subsequent shell integer comparisons rejected with `[: 0\n0: integer expression expected`. Same bug surfaced as `line 3182: 0\n0: syntax error in expression` inside `$((before_auto - after_auto))` in the reset path, where it cascaded into `unknown agent 'agentbox'` from the dispatch chain. Fix: drop the `|| echo 0` and use a defensive `[ -z "$x" ] && x=0` instead.

- **`prompt_approval` crash on `/dev/tty` without a controlling terminal** (`95d056f`). The TTY fallback's `[ -r /dev/tty ]` test passes whenever the device node is readable, but in a daemonised handler subprocess (decide-server spawns the handler) there's no controlling terminal and `read -r ans < /dev/tty` errors with ENXIO. With `set -u`, the next reference to `$ans` aborted the handler ("ans: unbound variable"), the handler exited 1, the decide-server returned 500, and openshell's interactive enforcement fell back to deny — making the user's allow click silently impossible. Fix: probe open-ability with `{ : < /dev/tty; } 2>/dev/null` (forces ENXIO to surface), initialize `local ans=""`, tolerate read failures.

- **Wildcard `Allow` on apex hosts no longer silently fails** (`ed04028`). See above under "Policy template".

### Documentation

- **`docs/openshell-interactive-enforcement.md`** — full integration spec, kept in sync with upstream changes; documents the supervisor-cache + sandbox-recreate gotcha discovered the hard way.
- **`docs/testing-fork-in-vm.md`** — Lima VM walkthrough for building openshell from source, replacing the supervisor cache, and running the full integration test (256 lines).
- **`docs/baseline-vs-branch-confidence-tests.md`** — 11-scenario test matrix run three times: vs main, vs branch with bearer-token auth, vs branch in opt-out mode. Verifies the branch is a strict superset of main + the new interactive path works end-to-end (214 lines).
- **CLAUDE.md rule 10** rewritten to cover the new wire-protocol fields, configurable bind, and opt-in `AGENTBOX_INTERACTIVE_POLICY=1` policy block.
- **Upstream bug docs** (in `vshalpnjabi/OpenShell/docs/interactive-enforcement/`): authored `PHASE4_BLOCKER.md` (rsa/pkcs8), `L7_DENY_RULES_NOT_FIRING.md` (policy schema), `SUPERVISOR_DECIDE_POST_NEVER_REACHES_ENDPOINT.md` (HTTP_PROXY recursion + tokio thread starvation + DNS resolver). All three resolved upstream by the time this release ships.

### Compatibility

- **Stock openshell users**: no behavior change. The `interactive_gate` block written into new policies is silently downgraded to plain `enforce` by stock openshell. The L4 watcher path continues to handle unknown hosts as before (403 then retry).
- **Fork openshell users** (via `AGENTBOX_INTERACTIVE_OPENSHELL=1` or self-built): held-connection prompts on first attempt, no retry needed.
- **Per-workspace opt-out**: `AGENTBOX_NO_INTERACTIVE_POLICY=1` in the shell makes new workspaces emit no `interactive_gate` block — exactly main's behavior.

## [v0.3.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.3.0) — 2026-05-27

Headline: **L4 watcher decisions now route through the decide-server (default-on)**, giving us a single decision pipeline that's already exercised in production while we wait for openshell upstream to ship `enforcement: interactive`. Wildcard approvals (`Allow all *.parent.host`) gain a third button on every prompt UI.

### New features

- **Decide-server is now default-on; watcher routes L4 decisions through it (unified L4+L7 decision pipeline)** (`71a1bca`). The watcher catches openshell's CONNECT denial (L4), SIGSTOPs the agent, POSTs the request to the local decide-server (`source: watcher`), receives a JSON decision, then unfreezes + optionally retry-injects. The decide-server is the single source of truth for prompts, policy updates, and seen-list writes — same code path whether the request originated from L7 openshell (future, when upstream lands `enforcement: interactive`) or L4 watcher (today). Watcher's previous direct-prompt path remains available via `AGENTBOX_NO_DECIDE_SERVER=1` for users who want the v0.2.0 behavior. Audit log tags every decision with `[src=watcher|openshell]` so you can tell where it originated. Response JSON now carries `kind` (`exact` vs `wildcard`) and `effective_host` (the host actually added to policy).

- **`Allow all *.parent.host` — a third option in every approval prompt** (`6e9607b`, label renamed in `7e6470c`). Wildcard derived automatically from the host (strip leftmost label): `static.rust-lang.org` → `*.rust-lang.org`; `download.crates.io` → `*.crates.io`. Wired into all backends — alerter (3rd `--actions` button), osascript modal (3rd button), zenity (`--list`), ntfy (3rd inline http action), `/dev/tty` (a/w/d keys). When clicked, calls `openshell policy update --add-endpoint *.parent:port` so one click covers the whole zone (rustup, cargo, etc.). Audit log distinguishes `ALLOW` vs `ALLOW_WILDCARD`.

### Behavioral changes

- **Direction-aware seen-list** (`cb5ae58`). v0.2.0 re-prompted on every deny including tuples you'd previously *allowed*, which became chatty. New default: `allow` / `allow_wildcard` decisions suppress future prompts (you said yes once, no need to ask again); `deny` decisions re-prompt (so you can change your mind, and so openshell hot-reload misses still surface). `AGENTBOX_SUPPRESS_REPEATS=1` opts back into the v0.1.0 "decide once, never re-prompt" mode (suppress denies too). `watcher-seen.txt` format extended from `binary|host|port` to `binary|host|port|decision`; legacy entries are treated as `legacy` and re-prompted once, then stored with the new format going forward.

- **Cleaner post-approval notification** (`f5cb8f2`). Dropped the `Tell agent to retry` suffix from the macOS notification — it was visual noise when `AGENTBOX_FORCE_RETRY=1` handles retry automatically and informational otherwise. Now reads just `host:port allowed.`

- **Cleaner macOS alerter banner: no more "Show"/"Options" dropdown** (`7e6470c`). macOS notifications support exactly one primary action button — passing 2+ actions to alerter rendered them as a dropdown menu. Now alerter shows a clean two-state Allow / Deny banner. The wildcard option (`Allow all *.host`) is still natively available on the osascript modal fallback (3-button dialog), zenity (Linux list), ntfy push (3 inline buttons), and the /dev/tty fallback. For wildcard prompts on macOS, prefer ntfy push (`export AGENTBOX_NTFY=1`).

### Bug fixes

- **Watcher silent-exit at first launch** (`40398ea`). `pgrep -f <pattern>` returns exit code 1 when no orphan watchers match — which is the *correct* state immediately after the previous orphan-fix landed. Under the script's `set -euo pipefail`, the failing command substitution silently aborted the entire dispatch at `watcher_ensure`, so `claude` printed two credential-sync lines and exited without opening the TUI. Fix: add `|| true` to all four pgrep pipelines in `watcher_ensure` and `watcher_stop`.

- **Concurrent watchers racing on `--add-endpoint`** (`cc5a4e8`). Root cause of the prior "I clicked Allow but the policy didn't update" complaint. Multiple watcher processes were accumulating (each `claude` launch spawned a new one and the pid file only tracked the latest), and each Allow's `openshell policy update --add-endpoint` read policy version N, pushed N+1 with their addition, and the last write won — overwriting the others' updates. Fix: both `watcher_ensure` and `watcher_stop` now use `pgrep -f "agentbox.sh __watch $sandbox"` to find ALL watchers for the sandbox (not just the tracked one). `watcher_ensure` kills orphans defensively at start; `watcher_stop` SIGTERMs then SIGKILLs all matches. Watcher count is now strictly 0 or 1 per sandbox.

### Documentation

- **CHANGELOG now exists** (`14028d1`, `809ed58`) — v0.2.0 entry retroactive, v0.3.0 entry curated.
- **RESUME.md rewritten for post-v0.3.0 state** (`6eb9970`) — documents the L4/L7 architecture, the L7 trigger gap (awaiting upstream openshell), and a CONTINGENCY plan: build a custom CONNECT-proxy interceptor inside agentbox if upstream Interactive enforcement stalls 3+ months. Decision criteria + implementation hints included so future-us can pick this up cleanly.
- **Known issue resolved**: `openshell policy update --add-endpoint --wait` silent no-op (RESUME.md). Clean repro with single watcher confirmed it works correctly; the orphan-watcher race fix (cc5a4e8) was the entire bug.

## [v0.2.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.2.0) — 2026-05-26

### Highlights

- **Default-on tmux wrap** around every TTY agent launch, on a private `-L agentbox` socket. Enables focus-independent retry-injection via `tmux send-keys`, detach/reattach (Ctrl-B d + `agentbox attach`), and shows the sandbox name in the status bar. Opt out: `AGENTBOX_NO_TMUX=1`.
- **`AGENTBOX_FORCE_RETRY`** auto-injects a `retry` prompt into the agent after Allow. Char-by-char typing defeats Claude Code's paste-detect / multi-line input mode. Configurable: `AGENTBOX_RETRY_PROMPT`, `AGENTBOX_RETRY_TYPING_DELAY`, `AGENTBOX_RETRY_SUBMIT_DELAY`, `AGENTBOX_RETRY_SUBMIT_KEY`.
- **Default: always re-prompt** on every network deny — even tuples decided on before. Catches openshell policy hot-reload failures (where `policy update --add-endpoint` reports success but doesn't actually apply). Opt back into v0.1.0's "decide once, never re-prompt" behavior with `AGENTBOX_SUPPRESS_REPEATS=1`.
- **In-sandbox NOPASSWD sudo** — `agentbox sudo enable` writes `/etc/sudoers.d/agentbox` via `docker exec -u 0` (auto-installs the sudo binary via apt/apk/dnf/yum if missing). Stays fully contained — sudo here cannot reach the host. Opt-in.

### New subcommands

- **`agentbox attach [NAME]`** — reattach to the workspace's tmux session (after a Ctrl-B d detach or terminal close).
- **`agentbox ssh [NAME] [-- cmd args...]`** — SSH into the sandbox via the agentbox-managed `~/.ssh/config` block. Supports one-shot commands: `agentbox ssh -- ls -la /sandbox/work`. Uses `ssh -t` for cleaner PTY than `openshell sandbox exec --tty`.
- **`agentbox resize`** — adjust sandbox cpu/memory via `.agentbox.toml`, with optional `--apply` for one-step destroy+recreate. Host state preserved across recreate.
- **`agentbox sudo {enable|disable|status}`** — toggle NOPASSWD sudo inside the sandbox.
- **`agentbox decide {status|start|stop|test|logs|seen}`** — manage the host-side decide-server (opt-in via `AGENTBOX_DECIDE_SERVER=1`).

### Decide-server (host-side HTTP endpoint for openshell's forthcoming Interactive mode)

- New `bin/agentbox-decide.py` — Python 3 stdlib HTTP server, binds 127.0.0.1, polling `handle_request` loop (deadlock-free SIGTERM).
- New `__decide` hidden subcommand in `agentbox.sh` — reads request JSON on stdin, hits the decision cache (separate from watcher's seen-list), otherwise drives `prompt_approval` and returns response JSON.
- New lifecycle helpers parallel to the watcher: `decide_server_ensure`, `decide_server_stop`. Deterministic port from sandbox-hash. pid/port/log in the state dir.
- Wired into agent dispatch + `cmd_destroy` + `cmd_stop`.
- Doctor row for `python3`.
- Requires upstream openshell support that doesn't exist yet — tracked at [vshalpnjabi/OpenShell `interactive-enforcement`](https://github.com/vshalpnjabi/OpenShell/tree/interactive-enforcement). Gated behind `AGENTBOX_DECIDE_SERVER=1` until then.

### Tmux wrap details

- Sessions live on a private socket (`tmux -L agentbox`) so agentbox's options + key bindings don't pollute the user's normal tmux setup.
- Server-global options applied on every attach: `mouse on`, `history-limit 10000`, custom `status-left` showing `agentbox:<workspace>-<hash>`.
- `MouseDown1Pane → cancel` binding in copy-mode tables so clicks exit copy-mode instead of getting stuck after scroll-wheel triggers it.
- Auto-skipped when the launching shell is already inside tmux (`$TMUX` set) — agentbox doesn't nest.
- `cmd_destroy` + `cmd_stop` now call `tmux_kill_session` so orphans don't linger.

### Install / prerequisites

- **tmux added** as a brew/apt prerequisite. The bootstrap auto-installs it on macOS; doctor reports the state.
- **python3** is added as an info-level row in doctor (only required if `AGENTBOX_DECIDE_SERVER=1`).
- **`agentbox installed (<version>)`** — the empty parens version-print regression in the install success line is fixed.

### Bug fixes

- Watcher unfreeze now happens **before** retry-inject (was after). Otherwise typed chars accumulated in the pty buffer during SIGSTOP and arrived in one burst on SIGCONT — the exact paste-detect trigger the char-by-char typing was designed to avoid.
- Decide-server Python uses a polling `handle_request` loop instead of `serve_forever` — `server.shutdown()` from the SIGTERM handler deadlocked because shutdown waits for serve_forever to acknowledge from the same thread.
- `exec agb_tmux` → `exec tmux -L "$AGB_TMUX_SOCKET"`. `exec` requires a binary, not a shell function — the previous form failed with `exec: agb_tmux: not found`.
- Status-left format string: bash's `${VAR:-default}` parameter expansion was eating the closing `}` of tmux's `#{s/.../.../:session_name}` substitution. Fixed by lifting the default into a separate variable.
- Sudo setup: switched from `openshell sandbox exec --user root` (the `--user` flag doesn't exist) to `docker exec -u 0 <container-id>` against the underlying Docker container. Auto-installs the sudo binary via apt/apk/dnf/yum when missing.
- Watcher Allow branch's nudge notification works again — was getting swallowed by the new `AGENTBOX_FORCE_RETRY` gate.

### Behavioral changes

- The seen-list (`watcher-seen.txt`, `decide-seen.txt`) is **no longer consulted for suppression by default**. It's still maintained for audit. Set `AGENTBOX_SUPPRESS_REPEATS=1` to restore v0.1.0 behavior.
- New default tmux wrap means closing the terminal window no longer kills the agent — it detaches. Reattach with `agentbox attach`. To kill the agent + sandbox: `agentbox destroy`.

### Full commit list

```
git log v0.1.0..v0.2.0 --oneline
```

23 commits. See [v0.2.0 release notes on GitHub](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.2.0) for the curated summary.

---

## [v0.1.0](https://github.com/vshalpnjabi/agentbox/releases/tag/v0.1.0) — 2026-05-26

Initial public release. Core feature set:

- **Per-workspace openshell sandboxes**, named deterministically `agentbox-<basename>-<sha256(abs_path)[:8]>`.
- **Shim symlinks** (`claude` / `codex` / `opencode`) routing through `agentbox.sh`. PATH-prefixed install.
- **mutagen two-way sync** of workspace ⇄ `/sandbox/work` and `~/.claude/projects` ⇄ host state dir (so `claude --continue` survives sandbox loss).
- **Auto-authentication** — synthetic `.credentials.json` + `~/.claude.json` + `CLAUDE_CODE_OAUTH_TOKEN` injection. Same approach for `codex` / `opencode`.
- **Approval watcher** — tails openshell logs for `NET:OPEN DENIED`, SIGSTOPs the agent, prompts via alerter / osascript / zenity / notify-send / ntfy.sh.
- **Per-workspace `.agentbox.policy.yaml`** auto-generated with reasonable defaults; hot-reloadable via `agentbox policy reload`.
- **Per-workspace `.agentbox.toml`** for image/cpu/memory/policy overrides.
- **`agentbox doctor`** prerequisite checker with `--fix` to open macOS Settings panes.
- **`agentbox uninstall`** tiered removal (shims → sandboxes → ssh config → state → tokens → workspaces).
- **Cross-platform install** — macOS, Linux, WSL via `install.sh`; Windows via `install.ps1` / `install.bat` (bootstrap into WSL).
- **ntfy.sh push notifications** as an opt-in cross-device approval backend.
