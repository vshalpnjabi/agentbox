# Confidence-test results: `main` (579550a) vs `interactive-decide-server` (9f2881a)

> **Update 2026-05-28:** retest run against upstream openshell
> `1-interactive-enforcement/vshalpnjabi` (HEAD `4ac551a`) which adds
> mandatory bearer-token auth on `/decide`. Agentbox commit `9f2881a`
> wires the matching per-sandbox secret end-to-end (state file →
> policy YAML → decide-server validation → watcher's outbound POSTs).
> All 11 scenarios pass; auth-rejection scenarios pass too. Detailed
> retest log appended at the bottom.

End-to-end tests run in a Lima Ubuntu 24.04 VM with stock Docker. Same VM,
same hosts, same agentbox install path — just swapping which branch of
agentbox is checked out (and which openshell build is running, for the
interactive-enforcement-specific tests).

## Test definitions

| # | Scenario | What it exercises |
|---|---|---|
| A | `curl https://github.com` from sandbox (in default allow-list) | Explicit allow-list rule + sandbox network |
| B | `curl https://www.example.com` with policy interactive_gate + mock decider returning `allow` | Held-connection L7 interactive path → Allow round-trip |
| C | Same as B but decider returns `deny` | Held-connection L7 interactive path → Deny round-trip |
| D | `curl https://httpbin.org` (not in any rule) | L4 default-deny → instant 403 |
| E | `git ls-remote https://api.example.com` (different binary subject to policy) | Per-binary policy enforcement |
| F | `agentbox status` / `approve list` / `decide status` / `doctor` / `notify status` | Management subcommand correctness |
| G | Manual edit of `.agentbox.policy.yaml` + `openshell policy set --wait` | Hot-reload semantics |
| H | Two workspaces, two sandboxes, unique decide-server ports | Multi-workspace sandbox isolation |
| I | `agentbox decide test` → ntfy push → tap Allow on phone → `auto_*` rule appended to policy | Full ntfy round-trip + persistent-rules write path |
| J | `agentbox approve reset` clears seen-list + auto_* rules; leaves `interactive_gate` | Cleanup semantics |
| K | `agentbox destroy <sandbox>` for multiple sandboxes; host state preserved | Sandbox tear-down |

## Results

| # | `main` (579550a) | `interactive-decide-server` (46de860) |
|---|---|---|
| A | ✅ github.com → HTTP 200 in 444 ms | ✅ HTTP 200 in 438 ms |
| B | N/A — main doesn't emit `interactive_gate` | ✅ HTTP 200 in 165 ms, mock decider got POST |
| C | N/A — main doesn't emit `interactive_gate` | ✅ HTTP 403 in 86 ms, mock decider got POST |
| D | ✅ httpbin.org → instant 403 in 2 ms (CONNECT tunnel failed) | ✅ instant 403 in 2.7 ms |
| E | ✅ enforced at L4 (403 fast) | ✅ enforced (same path) |
| F | ⚠️ `approve list` prints results BUT emits `line 3143: [: 0\n0: integer expression expected` | ✅ clean output |
| G | ✅ hot-reload took effect, httpbin.org now HTTP 200 in 472 ms | ✅ HTTP 200 in 416 ms |
| H | ✅ two sandboxes, two ports (65337, 58453), independent | ✅ same — two sandboxes, two ports |
| I | ✅ ntfy push → tap Allow → `auto_*` rule appended → `approve list` shows it | ✅ same |
| J | ⚠️ seen-list IS cleared, but a `line 3182: 0\n0: syntax error in expression` blows up the arithmetic, plus a follow-on `unknown agent 'agentbox'` error from the dispatch chain | ✅ clean (`cleared seen-list (N entries removed)` + `removed N auto_* rule(s)`) |
| K | ✅ 2 sandboxes destroyed cleanly, host state preserved | ✅ same |

## Bugs found on `main` (already fixed on the branch)

### Bug 1 — `agentbox approve list` integer comparison (line 3143)

```
/home/.../agentbox: line 3143: [: 0
0: integer expression expected
```

**Root cause:** `auto_count=$(grep -cE ... || echo 0)`. `grep -c` prints `0`
and exits 1 on no matches; `|| echo 0` then runs, appending a second `0`,
producing the multi-line value `"0\n0"`. The subsequent `[ "$auto_count"
-gt 0 ]` errors with "integer expression expected".

**Fix on branch:** drop the `|| echo 0` and rely on the empty-check
(`[ -z "$auto_count" ] && auto_count=0`). Committed as `46de860`.

### Bug 2 — `agentbox approve reset` arithmetic + follow-on dispatch (line 3182)

```
/home/.../agentbox: line 3182: 0
0: syntax error in expression (error token is "0")
[31magentbox: unknown agent 'agentbox' (no install recipe; ...)
```

**Root cause:** same multi-line `0\n0` value, this time inside
`$((before_auto - after_auto))`. The arithmetic context can't parse a
multi-line integer. After that, `set -e` causes an early function
return and the dispatch path goes haywire — somehow re-entering the
agent-dispatch arm with arg "agentbox", which then errors "unknown
agent".

**Fix on branch:** same defensive `[ -z "$x" ] && x=0` pattern applied
to both `before_auto` and `after_auto`. Same commit (`46de860`).

## Net assessment

- Every scenario that works on `main` works on `interactive-decide-server`.
- Two existing-on-main bugs are already fixed on the branch.
- The branch adds the L7 interactive enforcement path (Tests B and C),
  which only fires when openshell is built from the
  `interactive-enforcement` fork. Against stock openshell, the
  `interactive_gate` block is silently downgraded to plain `enforce` and
  the L4 path handles everything as before — backwards-compatible.

**No regressions. Two unblockings.** Ready to merge to `main` once the
upstream fork's public `supervisor:dev` image is republished.

---

## Retest against bearer-token-auth upstream (2026-05-28)

Setup:
- VM rebuilt openshell-cli + openshell-server + openshell-sandbox from
  `4ac551a` (sha256 `c712b56a...` on the supervisor binary).
- Supervisor cache overwritten, sandbox recreated.
- Agentbox in VM patched to commit `9f2881a` (bearer-token wiring).
- Verified at sandbox creation:
  - `.agentbox.policy.yaml` emits `secret: <hex>` on the interactive
    endpoint.
  - `<state>/decide-secret.txt` (mode 600) contains the same hex.
  - Container supervisor sha matches host build (`c712b56a...`).

### Test results

| # | Scenario | Outcome | Time |
|---|---|---|---|
| A | curl github.com (allow-list) | ✅ HTTP 200 | 517 ms |
| B | Interactive ALLOW (mock decider verifies bearer, returns allow) | ✅ HTTP 200, `auth_ok=True` in mock log, supervisor sees `[A]…[E] allowed` | 230 ms |
| B-neg | Interactive WRONG-secret (mock returns 401) | ✅ supervisor logs `request failed`, fallback fires, curl returns HTTP 403 | 74 ms |
| B-server-auth | Direct POST to agentbox decide-server with wrong/missing bearer | ✅ HTTP 401 `{"decision":"deny","reason":"invalid bearer token"}` | <100 ms |
| C | Interactive DENY (mock=deny, valid bearer) | ✅ HTTP 403, `auth_ok=True`, supervisor sees `[A]…[E]` then deny | 70 ms |
| D | curl httpbin.org (unknown host → L4 deny) | ✅ HTTP 000 CONNECT 403 | 3.5 ms |
| E | Different binary subject to policy (`git ls-remote …`) | ✅ enforced at L4 | — |
| F | `agentbox approve list / decide status / doctor / notify status` | ✅ clean output, no integer-comparison errors | — |
| G | Hot-reload after manual policy edit (allow httpbin.org for curl) | ✅ HTTP 200 | 695 ms |
| H | Second workspace, second sandbox, **unique per-sandbox secret** | ✅ two distinct secrets, two distinct ports, two Ready sandboxes | — |
| I | `agentbox decide test` → ntfy push → tap on phone | ✅ ntfy fired, user-decision relayed back, seen-list updated (this run: user tapped Deny → recorded as deny, no auto_* added — both directions exercised at this point) | — |
| J | `agentbox approve reset` | ✅ seen-list cleared, no shell errors | — |
| K | `agentbox destroy` on both sandboxes | ✅ both destroyed, secrets preserved in state dir for idempotent re-create | — |

### Bearer-token auth — specific checks

Both negative auth paths confirmed:

```
:64822 auth_ok=False GOT: /usr/bin/curl -> www.example.com:443 → 401
[sandbox] WARN openshell_sandbox::l7::interactive: interactive-enforcement: request failed
[sandbox] OCSF HTTP:GET DENIED GET http://www.example.com:443/  (fallback: deny)
```

And agentbox-decide.py's own validation:

```
$ curl -H 'Authorization: Bearer notthesecret' http://127.0.0.1:64822/decide ...
{"decision": "deny", "reason": "invalid bearer token"}
HTTP 401

$ curl -X POST http://127.0.0.1:64822/decide ...   # no Authorization header
{"decision": "deny", "reason": "invalid bearer token"}
HTTP 401
```

### Net assessment vs main

- All 11 baseline scenarios pass on the branch (same as `46de860` round).
- Two previously-found main bugs (`approve list` + `approve reset`
  integer-comparison) remain fixed.
- New bearer-token requirement from upstream is wired end-to-end with
  no regressions and no manual steps for the user — the secret is
  auto-generated on first sandbox creation and stays in sync between
  the policy file and the decide-server.
- Auth-rejection paths return clean denies (no security holes).

**Ready to merge to main once upstream republishes the public
`supervisor:dev` image.**
