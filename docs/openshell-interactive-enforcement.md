# agentbox × OpenShell Interactive Enforcement — Integration Guide

**For:** A Claude Code session working inside the `agentbox` repository.  
**Status:** OpenShell-side implementation is **complete** on branch
`interactive-enforcement` of `vshalpnjabi/OpenShell`.  
**Goal:** Add an HTTP decision server to agentbox so the OpenShell proxy can
hold denied requests open while the user approves or rejects them, instead of
immediately 403-ing.

---

## Background — why this matters

Today's flow (with SIGSTOP):

```
agent → request → proxy → 403 → agent sees failure
               ↓
         agentbox freezes agent (SIGSTOP)
         shows notification → user clicks Allow
         resumes agent (SIGCONT)
         agent RETRIES the request → succeeds
```

The problem: the 403 has already reached the agent's read buffer before the
user has decided anything. The agent must detect the failure and retry. This
is fragile — not all agents retry, and some interpret the 403 as a hard stop.

**With interactive enforcement:**

```
agent → request → proxy HOLDS connection → POSTs to agentbox's HTTP server
                                           agentbox shows notification
                                           user clicks Allow / Deny
                                           agentbox responds to proxy
                  proxy → 200 (Allow) ─────────────────────────────→ agent
                  proxy → 403 (Deny)  ─────────────────────────────→ agent
```

The agent is **already blocked** on its own outbound HTTP call — the proxy is
holding the TCP connection open. No SIGSTOP needed, no retry needed. The first
attempt is authoritative.

---

## What agentbox needs to add

A single HTTP handler:

```
POST /decide
Content-Type: application/json
```

That's it. The OpenShell proxy will POST a JSON body, wait for your response,
and act on `"allow"` or `"deny"`.

---

## Wire protocol

### Request body (sent by OpenShell proxy → agentbox)

```json
{
  "schema_version": 1,
  "request_id":   "550e8400-e29b-41d4-a716-446655440000",
  "sandbox_name": "agentbox-myproject-abc12345",
  "binary":       "/usr/local/bin/claude",
  "pid":          1244,
  "host":         "api.anthropic.com",
  "port":         443,
  "method":       "GET",
  "path":         "/v1/models",
  "protocol":     "rest",
  "policy_name":  "agentbox-interactive"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `schema_version` | `u8` | Always `1` for now |
| `request_id` | `string` | UUID v4 — unique per in-flight request; use as idempotency key |
| `sandbox_name` | `string` | Matches the name in agentbox's sandbox registry |
| `binary` | `string` | Full path of the binary making the connection |
| `pid` | `number` or absent | May be omitted if the proxy couldn't resolve it |
| `host` | `string` | Lowercase target hostname |
| `port` | `number` | Target port |
| `method` | `string` | HTTP method (`GET`, `POST`, etc.) |
| `path` | `string` | URL path |
| `protocol` | `string` | `"rest"`, `"graphql"`, or `"unknown"` |
| `policy_name` | `string` | Which policy rule matched this connection |

### Response body (agentbox → proxy)

```json
{ "decision": "allow", "reason": "user approved" }
```

or

```json
{ "decision": "deny", "reason": "user denied" }
```

| Field | Required | Notes |
|-------|----------|-------|
| `decision` | **yes** | Must be exactly `"allow"` or `"deny"` (lowercase). Any other value is treated as deny. |
| `reason` | no | Human-readable string; logged in the OCSF audit event. |

**HTTP status must be 2xx.** Any non-2xx status (even with `"decision":"allow"`
in the body) is treated as an error and the proxy applies its `fallback` mode
(default: deny).

### Error / timeout behaviour (proxy side)

The proxy has a per-endpoint `timeout_seconds` (default 60 s). If agentbox
doesn't respond within that window:
- The proxy applies the configured `fallback` (default: `deny`).
- The agent gets a clean 403.
- The proxy logs a warning with `timeout_ms`.

So agentbox should:
- Try to respond before `timeout_seconds − a few seconds` (leave buffer for
  network).
- If the user doesn't click in time, respond with `"deny"` explicitly rather
  than letting the proxy time out — cleaner for the audit log.

---

## Implementation checklist

### Step 1 — HTTP listener

Start an HTTP server bound to `0.0.0.0:53789` (or a configurable port) when
agentbox starts. This port must be reachable from the OpenShell gateway process.

> **Port note:** If OpenShell runs as a native daemon on macOS (not in a
> container), the proxy and agentbox are on the same machine, so `127.0.0.1`
> works fine. The policy YAML uses `host.openshell.internal` which resolves
> to the host machine's IP from within a sandbox container — so binding
> `0.0.0.0` is safer.

### Step 2 — Handle `POST /decide`

```
receive POST /decide
  1. Parse JSON body → extract all fields (schema_version check optional for now)
  2. Look up sandbox by sandbox_name in agentbox's registry
  3. Generate a user-facing prompt:
       "[sandbox_name]  binary→host:port path"
       "[Allow]  [Deny]"
  4. Show notification (ntfy, macOS alert, TUI prompt — whatever agentbox uses)
  5. Wait for user click, with a deadline of (timeout_seconds − 5 s)
  6. Respond:
       Allow → HTTP 200, {"decision":"allow","reason":"user approved"}
       Deny  → HTTP 200, {"decision":"deny","reason":"user denied"}
       No response in time → HTTP 200, {"decision":"deny","reason":"timed out waiting for user"}
```

### Step 3 — Relationship to existing SIGSTOP / seen-list machinery

You do **not** need to SIGSTOP the agent when interactive enforcement is
active — the agent is already blocked on its own HTTP call. The proxy is
holding the TCP connection open.

Recommended: keep the SIGSTOP path as a fallback for cases where interactive
enforcement is not configured (i.e., the sandbox is using plain `enforce`
mode). Interactive and SIGSTOP are complementary:

| Situation | Mechanism |
|-----------|-----------|
| Policy is `interactive` mode | Proxy holds connection → agentbox responds |
| Policy is `enforce` mode | Proxy 403s immediately → agentbox freezes + notifies (existing flow) |

The seen-list machinery (`freeze_sandbox_agents`, etc.) is orthogonal and can
stay unchanged.

### Step 4 — Concurrent requests

The proxy caps concurrent in-flight interactive calls at 16 (semaphore per
sandbox process). In practice you'll rarely see more than 1-2 simultaneous
decision requests per sandbox. But your HTTP handler should support concurrent
requests — don't hold a global lock while waiting for user input; track
in-flight decisions by `request_id`.

### Step 5 — Policy template

Add (or update) the default `.agentbox.policy.yaml` template so new sandboxes
get interactive enforcement by default on unconfigured hosts:

```yaml
network_policies:
  # Hosts in this list are always allowed without a prompt.
  claude_api:
    name: claude-api
    endpoints:
      - host: "api.anthropic.com"
        port: 443
        protocol: rest
        enforcement: enforce
    binaries:
      - path: /usr/local/bin/claude

  # Everything else requires user approval.
  interactive_gate:
    name: interactive-gate
    endpoints:
      - host: "*"
        port: 443
        enforcement:
          mode: interactive
          endpoint: http://host.openshell.internal:53789/decide
          timeout_seconds: 120
          fallback: deny
    binaries:
      - path: /usr/local/bin/claude
```

> Policy rules are evaluated in order; the first matching rule wins. Put
> explicit allow-list entries **before** the `"*"` interactive rule.

---

## End-to-end test plan

### Prerequisites

1. OpenShell built from `vshalpnjabi/OpenShell` branch `interactive-enforcement`
   and installed (`cargo install --path crates/openshell-cli`).
2. agentbox running with the decision server listening on `:53789`.

### Quick smoke test (mock server, no agentbox changes yet)

Before wiring agentbox, verify the OpenShell side with a standalone mock:

```python
# mock_decider.py
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, sys

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n))
        print(f"\n→ {body['binary']} → {body['method']} {body['host']}:{body['port']}{body['path']}")
        print(f"  sandbox: {body['sandbox_name']}  request_id: {body['request_id']}")
        ans = input("  [a]llow / [d]eny: ").strip().lower()
        resp = json.dumps({"decision": "deny" if ans == "d" else "allow",
                           "reason": "manual test"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def log_message(self, *_): pass

HTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 9999), H).serve_forever()
```

```bash
python3 mock_decider.py 9999
```

Policy endpoint for mock test: `http://127.0.0.1:9999/decide` (or
`http://host.openshell.internal:9999/decide` if inside a container).

### Test matrix

| Test | Expected |
|------|----------|
| User clicks Allow | Agent's request succeeds on the **first** attempt |
| User clicks Deny | Agent gets clean 403 on the first attempt |
| agentbox server not running | Proxy logs "request failed"; fallback fires; agent gets 403 |
| User doesn't click within `timeout_seconds` | Proxy logs "timed out"; fallback fires; agent gets 403 |
| Two concurrent denied requests | Both prompts appear; both can be Allow/Deny independently |
| Allow-listed host (e.g. api.anthropic.com) | No prompt; request passes through with `enforce` rule |

### Verifying `sandbox_name` round-trip

The `sandbox_name` in the decision request should match exactly what agentbox
used when it started the sandbox. Confirm this first — it's how agentbox maps
the incoming decision request back to the right sandbox in its registry.

---

## OpenShell installation (from the fork)

```bash
# On your Mac — build from the interactive-enforcement branch
brew uninstall openshell 2>/dev/null || true
cd ~/Library/CloudStorage/Dropbox/github.com/openshell-interactive-enforcement
cargo install --path crates/openshell-cli

# Restart the daemon
brew services stop openshell 2>/dev/null || true
openshell serve &
```

The feature is behind the policy YAML — existing sandboxes using
`enforcement: enforce` or `enforcement: audit` are unaffected.

---

## Reference

- **Full OpenShell design doc:** `docs/interactive-enforcement/DESIGN.md` in
  the `vshalpnjabi/OpenShell` `interactive-enforcement` branch.
- **Wire protocol source of truth:** `crates/openshell-sandbox/src/l7/interactive.rs`
  (`DecisionRequest` struct, `consult_interactive_endpoint` function).
- **Policy schema:** `crates/openshell-policy/src/lib.rs`
  (`InteractiveEnforcementDef` struct).
- **OpenShell fork PR:** `vshalpnjabi/OpenShell` (draft PR from
  `interactive-enforcement` branch).
