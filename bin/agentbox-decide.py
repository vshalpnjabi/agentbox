#!/usr/bin/env python3
# agentbox-decide.py — host-side HTTP decision endpoint for openshell's
# (forthcoming) Interactive enforcement mode.
#
# Implements the wire protocol from
#   github.com/vshalpnjabi/OpenShell (interactive-enforcement branch)
#   docs/interactive-enforcement/DESIGN.md
#
# POST /decide  body: JSON request (see DESIGN.md)
#               returns: {"decision": "allow"|"deny", "reason": "..."}
#
# Each request is delegated to a handler subprocess (agentbox.sh __decide ...)
# which prints the response JSON on stdout. The handler is responsible for the
# actual Allow/Deny UI (alerter / ntfy / etc.) — this script is just a thin
# HTTP front-end.
#
# Binds to 127.0.0.1 only by default. Sandbox→host reachability + auth (HMAC
# or Unix-socket transport) is deferred until openshell's Interactive mode
# actually exists upstream.

import argparse
import json
import os
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_TIMEOUT_SECONDS = 300


def _log(msg: str) -> None:
    sys.stderr.write(f"[agentbox-decide] {msg}\n")
    sys.stderr.flush()


def _consteq(a: str, b: str) -> bool:
    # hmac.compare_digest is constant-time over equal-length inputs;
    # short-circuits cleanly when lengths differ (still safe).
    import hmac
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


class DecideHandler(BaseHTTPRequestHandler):
    handler_cmd: list = []
    sandbox_name: str = ""
    expected_secret: str = ""  # populated from --secret-file at startup

    def log_message(self, fmt, *args):
        _log(fmt % args)

    def _auth_ok(self) -> bool:
        # No secret configured → backwards-compat (allow unauthenticated).
        # In production agentbox writes a per-sandbox secret on first
        # decide_server_ensure, so this empty branch is mostly a defense
        # for `decide test` invocations that may pre-date the secret.
        if not self.expected_secret:
            return True
        hdr = self.headers.get("Authorization", "")
        if not hdr.startswith("Bearer "):
            return False
        token = hdr[len("Bearer "):].strip()
        # Constant-time compare to avoid leaking secret length via timing.
        return _consteq(token, self.expected_secret)

    def _reply_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _reply_text(self, status: int, body: str) -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/health"):
            self._reply_json(200, {"status": "ok", "sandbox": self.sandbox_name})
            return
        self._reply_text(404, "not found\n")

    def do_POST(self):
        if self.path != "/decide":
            self._reply_text(404, "not found\n")
            return

        if not self._auth_ok():
            # 401 makes the openshell proxy treat this as an error and apply
            # `fallback: deny` (cleaner than letting the handler run). The
            # body is for human debuggers.
            self._reply_json(401, {"decision": "deny", "reason": "invalid bearer token"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._reply_json(400, {"decision": "deny", "reason": "invalid Content-Length"})
            return

        raw = self.rfile.read(length) if length > 0 else b""
        try:
            req = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            self._reply_json(400, {"decision": "deny", "reason": f"bad JSON: {e}"})
            return

        # Stamp sandbox_name if the caller omitted it. This lets `agentbox
        # decide-test` and other ad-hoc clients work without filling in every
        # field — the openshell proxy always sends it.
        req.setdefault("sandbox_name", self.sandbox_name)
        req.setdefault("schema_version", 1)

        env = os.environ.copy()
        env["AGENTBOX_DECIDE_SANDBOX"] = self.sandbox_name

        try:
            proc = subprocess.run(
                self.handler_cmd,
                input=json.dumps(req).encode("utf-8"),
                capture_output=True,
                timeout=DEFAULT_TIMEOUT_SECONDS,
                env=env,
            )
        except subprocess.TimeoutExpired:
            _log(f"handler timed out after {DEFAULT_TIMEOUT_SECONDS}s; fail-closed")
            self._reply_json(504, {"decision": "deny", "reason": "handler timeout"})
            return
        except Exception as e:
            _log(f"handler error: {e}")
            self._reply_json(500, {"decision": "deny", "reason": f"handler error: {e}"})
            return

        if proc.returncode != 0:
            stderr_tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
            _log(f"handler exited {proc.returncode}: {' | '.join(stderr_tail)}")
            self._reply_json(500, {"decision": "deny", "reason": f"handler exit {proc.returncode}"})
            return

        try:
            out = json.loads(proc.stdout.decode("utf-8", "replace"))
        except json.JSONDecodeError as e:
            tail = proc.stdout.decode("utf-8", "replace").strip()[-200:]
            _log(f"handler returned non-JSON: {e} | tail={tail!r}")
            self._reply_json(500, {"decision": "deny", "reason": "handler returned non-JSON"})
            return

        decision = str(out.get("decision", "")).lower()
        if decision not in ("allow", "deny"):
            _log(f"handler returned bad decision: {out!r}")
            self._reply_json(500, {"decision": "deny", "reason": "handler bad decision"})
            return

        reply = {"decision": decision}
        if "reason" in out and out["reason"] is not None:
            reply["reason"] = out["reason"]
        self._reply_json(200, reply)


def main() -> int:
    ap = argparse.ArgumentParser(description="agentbox decide endpoint")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--sandbox", required=True, help="Sandbox name this server serves")
    ap.add_argument(
        "--handler",
        required=True,
        help="Shell command invoked per request with JSON on stdin (must print JSON to stdout)",
    )
    ap.add_argument("--pid-file", help="Write own PID to this file")
    ap.add_argument(
        "--secret-file",
        help="Path to a file holding the shared bearer token. Required-Authorization "
             "for every POST /decide. Omitted/missing/empty file → unauthenticated mode "
             "(backwards compat; not recommended).",
    )
    args = ap.parse_args()

    # The handler is a shell command line; let /bin/sh parse it.
    handler_cmd = ["/bin/sh", "-c", args.handler]

    DecideHandler.handler_cmd = handler_cmd
    DecideHandler.sandbox_name = args.sandbox

    expected_secret = ""
    if args.secret_file:
        try:
            with open(args.secret_file, "r") as f:
                expected_secret = f.read().strip()
        except OSError as e:
            _log(f"could not read --secret-file {args.secret_file}: {e}; running unauthenticated")
    DecideHandler.expected_secret = expected_secret
    if expected_secret:
        _log(f"bearer-token auth enabled (secret loaded from {args.secret_file})")
    else:
        _log("bearer-token auth DISABLED (no --secret-file or empty); accepting any POST")

    if args.pid_file:
        try:
            with open(args.pid_file, "w") as f:
                f.write(str(os.getpid()))
        except OSError as e:
            _log(f"could not write pid file {args.pid_file}: {e}")

    # ThreadingHTTPServer spawns a thread per request so a long-running handler
    # (e.g. waiting on an ntfy user response for ~120 s) doesn't stall the
    # accept() loop or block parallel /decide POSTs from concurrent agents.
    server = ThreadingHTTPServer((args.bind, args.port), DecideHandler)
    server.daemon_threads = True  # don't block shutdown on in-flight requests
    # 0.5s timeout on accept() — lets the main loop respond to SIGTERM/SIGINT
    # promptly without depending on serve_forever's internals. Calling
    # server.shutdown() from a signal handler deadlocks against serve_forever's
    # main thread; this polling loop sidesteps that entirely.
    server.timeout = 0.5

    keep_running = [True]

    def _shutdown(signum, frame):
        _log(f"signal {signum} received; shutting down")
        keep_running[0] = False

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    _log(
        f"listening on {args.bind}:{args.port} for sandbox={args.sandbox}; "
        f"handler={args.handler}"
    )
    try:
        while keep_running[0]:
            server.handle_request()
    finally:
        try:
            server.server_close()
        except OSError:
            pass
        if args.pid_file and os.path.exists(args.pid_file):
            try:
                os.remove(args.pid_file)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
