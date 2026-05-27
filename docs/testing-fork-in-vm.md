# Testing the openshell interactive-enforcement fork in an isolated Lima VM

Run end-to-end test B (held-connection prompt + agentbox `/decide` round-trip)
without polluting your Mac. Everything below happens inside a throwaway
Lima VM you can `delete` when done.

**Why Lima, not plain Docker?** OpenShell's gateway is a long-running daemon
that uses Docker to create sandboxes. Running gateway *inside* Docker means
Docker-in-Docker, which is flaky on macOS. Lima gives you a real Linux VM
that runs both the gateway daemon AND its own Docker daemon for sandboxes —
clean separation, no DinD pain.

## Prerequisites on the Mac

```bash
brew install lima
# Phone with the ntfy app installed (App Store / Google Play) — see
# "Approval prompt UI" below.
```

## 1. Create the VM

```bash
limactl start --name=openshell-test \
  template://ubuntu-lts \
  --cpus 4 --memory 8 --disk 40
# ~3-5 min cold; subsequent starts are seconds
```

Drop into it:

```bash
limactl shell openshell-test
```

Everything from here through teardown runs inside the VM unless otherwise
called out.

## 2. System dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential pkg-config clang \
  libz3-dev \
  docker.io \
  jq curl git python3 tmux
sudo usermod -aG docker $USER
# Re-evaluate group membership without logout
newgrp docker
# Smoke check
docker run --rm hello-world
```

## 3. Rust toolchain (matches the fork's pin to 1.95.0)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustc --version    # should be 1.95.0 once rustup picks up rust-toolchain.toml
```

## 4. Clone the fork and resolve the Phase 4 dep blocker

```bash
git clone --branch interactive-enforcement \
  https://github.com/vshalpnjabi/OpenShell.git \
  ~/openshell-fork
cd ~/openshell-fork
```

The fork was originally blocked by an `rsa 0.10.0-rc.12` ↔ `pkcs8 0.11.0`
type mismatch (see [`PHASE4_BLOCKER.md`](https://github.com/vshalpnjabi/OpenShell/blob/interactive-enforcement/PHASE4_BLOCKER.md)
in the fork if present). Two options:

**A.** Pin pkcs8 backward in the workspace `Cargo.toml` (recommended; check
the fork's HEAD first — they may have landed this fix already, in which
case skip to step 5):

```toml
# Add to [workspace.dependencies] in Cargo.toml
pkcs8 = "=0.10.2"
```

Then `cargo update -p pkcs8` and `cargo install …` should succeed.

**B.** Sed the cached rsa crate (works once; evaporates on `cargo clean`):

```bash
sed -i \
  's|_ => pkcs8::Error::KeyMalformed,|_ => pkcs8::Error::KeyMalformed(pkcs8::KeyError::Invalid),|' \
  ~/.cargo/registry/src/index.crates.io-*/rsa-0.10.0-rc.12/src/encoding.rs 2>/dev/null
# Idempotent — no-op if already patched or if crate was redownloaded.
```

## 5. Build the fork

```bash
source "$HOME/.cargo/env"
cd ~/openshell-fork
cargo install --path crates/openshell-cli    --bin openshell         --force
cargo install --path crates/openshell-server --bin openshell-gateway --force
# Binaries land at ~/.cargo/bin/{openshell,openshell-gateway}

# CRITICAL — also rebuild the supervisor binary. It's the OPA evaluator that
# runs *inside* sandbox containers; if you skip this, the new proxy on the
# gateway will run but the old OPA in the container will silently allow
# everything that touches L7 deny_rules.
cargo build --release -p openshell-sandbox
```

`cargo install` defaults to release profile — first build is ~5-10 min on
4 vCPUs. Subsequent rebuilds (after source edits) are seconds.

After the gateway starts once (next step), it'll pull
`ghcr.io/nvidia/openshell/supervisor:dev` and cache the supervisor
binary under `~/.local/share/openshell/docker-supervisor/sha256-*/`.
Overwrite that cached copy with the one you just rebuilt, then destroy
any existing sandboxes so they get recreated with the fresh supervisor:

```bash
for f in ~/.local/share/openshell/docker-supervisor/sha256-*/openshell-sandbox; do
  cp target/release/openshell-sandbox "$f"
done
~/.cargo/bin/openshell sandbox list | awk 'NR>1 {print $1}' \
  | xargs -n1 ~/.cargo/bin/openshell sandbox delete 2>/dev/null
```

## 6. Start the gateway daemon

```bash
mkdir -p ~/openshell-state
nohup ~/.cargo/bin/openshell-gateway \
  > ~/openshell-state/gateway.log 2>&1 &
sleep 2
~/.cargo/bin/openshell sandbox list   # should print empty header, not error
```

If `sandbox list` errors with "transport error", tail
`~/openshell-state/gateway.log` for the reason — usually missing TLS
config or env vars the brew install normally handles. The fork's
`crates/openshell-server/src/defaults.rs` lists what env vars matter.

## 7. Install agentbox + check out the interactive-decide-server branch

```bash
curl -fsSL https://raw.githubusercontent.com/vshalpnjabi/agentbox/main/install.sh | bash
cd ~/src/agentbox
git fetch origin
git checkout interactive-decide-server
# Make sure the live shim picks up this branch
ln -sf "$(pwd)/agentbox.sh" ~/.local/share/agentbox/agentbox.sh
readlink ~/.local/share/agentbox/agentbox.sh
```

## 8. Approval prompt UI — set up ntfy

A headless Lima VM has no `alerter` or `osascript`. The realistic backend
inside the VM is ntfy.sh — push notifications to your phone with inline
Allow/Deny buttons.

```bash
# Pick a hard-to-guess topic name (or let agentbox generate one)
agentbox notify setup --global agbox-fork-test-$(uuidgen | tr -d - | head -c 12)
# Outputs the topic URL. Subscribe on your phone in the ntfy app.
# --global also persists AGENTBOX_NTFY=1 + AGENTBOX_NTFY_TOPIC in your
# ~/.bashrc so every new shell auto-uses it.
source ~/.bashrc

# Smoke check
agentbox decide test example.com 443 /usr/bin/curl
# Phone should receive a 3-button push (Allow / Allow all *.example.com / Deny).
# Tap one, the curl POST inside agentbox returns the matching JSON.
```

## 9. Run test B end-to-end

```bash
mkdir -p ~/test-workspace && cd ~/test-workspace && git init -q

# Write the policy with the interactive_gate block
AGENTBOX_INTERACTIVE_POLICY=1 claude --version

# Confirm the policy has the interactive enforcement block (note: the template
# uses *.example.com as a demo target — change to your real gated host before
# real use; bare "*" does NOT work, see policy-gotchas note below)
grep -A 18 "example_interactive_gate:" .agentbox.policy.yaml
# Expect the three required pieces: protocol: rest, access: full, deny_rules
# (see docs/openshell-interactive-enforcement.md for why each matters)

# Get a shell inside the sandbox
agentbox ssh

# Inside the sandbox, hit a host NOT in the explicit allow-list
curl -v https://example.com
# Expected: curl HANGS (proxy is holding the TCP connection)
# On your PHONE: ntfy push with Allow / Deny buttons fires
# Tap Allow
# Back inside the sandbox: curl returns 200 — no retry, single-attempt
```

## 10. Verify the L7 path fired (not the L4 watcher fallback)

In another VM shell:

```bash
SB=$(ls -t ~/.local/share/agentbox/state | head -1)
tail -30 ~/.local/share/agentbox/state/$SB/audit.log \
  | grep -E "decide|PROMPT|USER_ALLOW"
```

Look for `src=openshell` in the PROMPT and USER_ALLOW lines — the `openshell`
source confirms the gateway-driven L7 path. `src=watcher` would mean the
L4 fallback ran (i.e., gateway returned 403 first and the watcher prompted
on the 403), which is wrong for interactive mode.

Also check that there is **no** `NET:OPEN ... DENIED` line for the host
just before the allow — the held-open semantics means the deny event
never fires.

## 11. Negative path

```bash
# Inside the sandbox
curl -v https://reddit.com
# ntfy push fires; tap Deny on phone
# Inside sandbox: 403 returned cleanly; no retry, no second prompt
```

Audit log should show `USER_DENY [src=openshell]` for this request.

## 12. Teardown

```bash
# Exit the VM shell
exit

# On the Mac
limactl stop openshell-test
limactl delete openshell-test
# Nothing else on the Mac to clean up — all build artifacts, sandboxes,
# state, and openshell binaries lived inside the VM.
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `cargo install` fails on `rsa` E0308 | Phase 4 dep blocker not patched | Step 4 option A or B |
| Phone gets no push | ntfy topic not configured / `AGENTBOX_NTFY=1` unset | `agentbox notify status` |
| `agentbox ssh` errors "sandbox not ready" | Gateway daemon not running | `ps aux \| grep openshell-gateway`, restart per step 6 |
| Curl gets immediate 403 instead of hanging | Policy didn't get interactive block / wrong endpoint port | Re-check `grep interactive_gate .agentbox.policy.yaml` |
| Audit log shows `src=watcher` not `src=openshell` | Gateway is from brew (stock), not the fork | `which openshell-gateway` should point at `~/.cargo/bin/...` |
| Build OOM-killed during link | VM RAM too small | `limactl stop openshell-test` then re-create with `--memory 12` |

## What this proves vs. the curl-driven smoke test (test A)

| | Test A (curl smoke) | Test B (this guide) |
|---|---|---|
| Wire-protocol parsing | ✅ | ✅ |
| Sandbox name validation | ✅ | ✅ |
| Prompt UI fires | ✅ | ✅ |
| Allow/Deny round-trip | ✅ | ✅ |
| **Gateway holds connection during prompt** | ❌ | ✅ |
| **First-attempt success on Allow (no retry needed)** | ❌ | ✅ |
| Setup time | 30 sec | ~30 min (one-time) |

Test A is fine for iterating on the agentbox parser. Test B is the proof
that the L7 path beats the L4-watcher-retry path. Use B once when the fork
is unblocked; thereafter iterate on A.
