#!/usr/bin/python3 -I
"""Connect once after login through the same broker client the bar uses.

Opt-in via the bundled user unit. Sends only the ordinary `connect` request,
so every broker precondition (default scope, management session, guard
lease) still applies; refusals are reported, never worked around.
"""
import json
import subprocess
import sys
import time

CLIENT = "/usr/local/bin/singbox-runtime"
DEADLINE = 240.0  # broker recovery after boot can take a while
RETRYABLE = {"unavailable", "timeout", "busy", "stale-revision", "stale-generation"}


def exchange(action, serial, revision=None, generation=None):
    request = {"action": action, "request_id": "autoconnect-%d" % serial}
    if revision is not None:
        request["catalog_revision"] = revision
    if generation is not None:
        request["runtime_generation"] = generation
    try:
        out = subprocess.run([CLIENT], input=json.dumps({"version": 1, "request": request}),
                             capture_output=True, text=True, timeout=200).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return {"ok": False, "error": {"code": "unavailable"}}


def revisions(response):
    rev, gen = response.get("catalog_revision"), response.get("runtime_generation")
    return (rev, gen) if type(rev) is int and type(gen) is int else None


def autoconnect(send=exchange, sleep=time.sleep, clock=time.monotonic):
    deadline, serial, last = clock() + DEADLINE, 0, "unavailable"
    while clock() < deadline:
        serial += 1
        # Revision 0 is never current: the stale-revision refusal carries the live pair.
        current = revisions(send("status", serial, 0))
        if current:
            serial += 1
            capture = send("capture_status", serial, current[0]).get("capture") or {}
            if capture.get("state") == "active" and capture.get("deadline_fresh") is True:
                return 0, "already connected"
            serial += 1
            response = send("connect", serial, *current)
            if response.get("ok"):
                return 0, "connected"
            last = (response.get("error") or {}).get("code") or "runtime-error"
            if last not in RETRYABLE:
                return 1, "refused: %s" % last
        sleep(3)
    return 1, "gave up: %s" % last


def _check():
    calls = []

    def fake(replies):
        def send(action, serial, *args):
            calls.append(action)
            return replies[action].pop(0) if isinstance(replies[action], list) else replies[action]
        return send

    stale = {"ok": False, "catalog_revision": 3, "runtime_generation": 9}
    assert autoconnect(fake({"status": stale, "capture_status": {"capture": {"state": "active", "deadline_fresh": True}}}),
                       sleep=lambda _: None) == (0, "already connected")
    assert autoconnect(fake({"status": stale, "capture_status": {"capture": {"state": "unprepared"}},
                             "connect": [{"ok": False, "error": {"code": "busy"}}, {"ok": True}]}),
                       sleep=lambda _: None) == (0, "connected")
    assert autoconnect(fake({"status": stale, "capture_status": {}, "connect": {"ok": False, "error": {"code": "default-unassigned"}}}),
                       sleep=lambda _: None) == (1, "refused: default-unassigned")
    ticks = iter(range(0, 1000, 100))
    assert autoconnect(fake({"status": {"ok": False}}), sleep=lambda _: None, clock=lambda: next(ticks))[0] == 1
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        _check()
        raise SystemExit(0)
    code, message = autoconnect()
    print("singbox-vpn autoconnect: " + message, file=sys.stderr if code else sys.stdout)
    raise SystemExit(code)
