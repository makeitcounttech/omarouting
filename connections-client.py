#!/usr/bin/env python3
"""Unprivileged connections client for the community.singbox-vpn panel.

One job: carry a bounded, versioned request to the root-owned connections
helper and carry its bounded response back. This process never mutates VPN
state and never activates anything — the helper owns the actions, and they
are catalog/persistence actions only.

Shape of the exchange:

  QML  --one bounded JSON line on stdin-->  this client
  client --fixed argv, request JSON on stdin-->  sudo -n /usr/local/bin/singbox-connections request
  client <--bounded response JSON--            the helper
  QML  <--the helper's own response JSON--  this client

Safety properties, all tested in tests/ui/test_connections_client.py:

- The helper is invoked with ONE fixed argv — no shell, no interpolation,
  nothing user- or file-derived in the command line. Request JSON and any
  secret bytes travel on the helper's stdin only: never argv, never the
  environment, never a log.
- Chosen files are read HERE, under the desktop user's own permissions,
  with regular-file + size bounds and no symlink following. The helper
  never opens a user-supplied filename.
- Input from QML is one bounded JSON object; the request body is bounded;
  the response is read under a byte cap and must be exactly one valid
  contract response (version 1, matching request_id, ok + data/error).
- Actions are allowlisted; anything else is refused before any process is
  spawned: list, preview_wireguard, import_wireguard, save, remove.

Automatic private-host lifecycle (the one and only second call):

  A successful helper `save` whose prepared payload kind is headscale, and
  every successful helper `remove`, is followed by exactly ONE
  client-generated sync_private_hosts request — empty payload, revision
  equal to the committed response revision, and a freshly generated
  internal request id. That second request carries ONLY the generated
  internal id/action/revision/payload: never credentials, never any part
  of the original payload, never the panel's request id. It runs under
  the same bounded runner and response contract as the first call.
  - Sync confirmed → the original successful save/remove response is
    emitted unchanged.
  - A successful save/remove answer WITHOUT an exact non-negative integer
    revision (a bool, a string, a float, a negative, or nothing) can never
    form a safe follow-up: the helper is not called a second time, no
    revision is invented, and the same host-sync-required envelope is
    emitted (without a revision) instead of a silent success.
  - Sync refused, contract-broken or unavailable → a sanitized ok:false
    envelope under the ORIGINAL request id with code host-sync-required:
    the catalog change IS committed (no rollback is claimed or attempted)
    and private hostname synchronization needs a retry or administrator
    review. The committed revision is included because the current
    response contract carries a top-level revision on helper replies.

Exit codes: 0 the helper answered (its JSON is on stdout, ok true or
false — including a chained host-sync-required envelope, which reports a
committed catalog change plus a pending host sync, not a lost change);
2 the helper could not be reached (not installed / not authorized);
3 bad input from the panel; 4 the helper answered outside the contract.
"""

import base64
import json
import os
import selectors
import stat
import subprocess
import sys
import time
import uuid

VERSION = 1
MAX_INPUT = 1 << 20          # 1 MiB from the panel
MAX_REQUEST = 12 * 1024 * 1024
MAX_RESPONSE = 1 << 20       # 1 MiB from the helper
MAX_STDERR = 1 << 16         # 64 KiB of helper stderr is plenty for a hint
MAX_FILE = 8 * 1024 * 1024   # a chosen .conf/.zip
MAX_KEYFILE = 64 * 1024      # an enrollment key file
MAX_TEXT = 128
HELPER = "/usr/local/bin/singbox-connections"
HELPER_VERB = "request"
HELPER_TIMEOUT = 30
ACTIONS = ("list", "preview_wireguard", "import_wireguard", "save", "remove")
WIREGUARD_KINDS = ("conf", "zip")
SAVE_KINDS = ("wireguard", "tailscale", "headscale", "proxy")
# Client-generated follow-up only: never accepted from the panel (the
# panel's allowlist above stays unchanged), never chained more than once.
SYNC_PRIVATE_HOSTS = "sync_private_hosts"

EXIT_OK = 0
EXIT_HELPER_MISSING = 2
EXIT_INPUT = 3
EXIT_CONTRACT = 4


class ClientError(Exception):
    pass


def sanitize_message(message):
    """One bounded line; never a payload echo."""
    return " ".join(str(message).split())[:200]


def is_code(value, max_len):
    v = str(value)
    return 0 < len(v) <= max_len and not any(
        ord(ch) < 32 or ord(ch) == 127 for ch in v)


def clean_text(value, max_len=MAX_TEXT):
    """Display text: control bytes become spaces, collapsed and bounded."""
    v = "".join(ch if ord(ch) >= 32 and ord(ch) != 127 else " "
                for ch in str(value or ""))
    v = " ".join(v.split())
    return v[:max_len]


def clean_filename(name):
    """A safe display filename: basename only, control bytes gone, bounded."""
    base = str(name or "").replace("\\", "/").rsplit("/", 1)[-1].strip()
    return clean_text(base, 255)


def read_regular_file_bounded(path, cap):
    """Read a chosen file under the desktop user's own permissions.

    Regular files only, no symlink following, size-capped before and after
    open (the second check catches a swap between stat and read).
    """
    if not isinstance(path, str) or path == "":
        raise ClientError("no file was chosen")
    if not os.path.isabs(path):
        raise ClientError("file path must be absolute")
    try:
        st = os.lstat(path)
    except OSError as e:
        raise ClientError("cannot read the chosen file: %s" % e.strerror)
    if stat.S_ISLNK(st.st_mode):
        raise ClientError("refusing to follow symlinks")
    if not stat.S_ISREG(st.st_mode):
        raise ClientError("the chosen file is not a regular file")
    if st.st_size > cap:
        raise ClientError("file exceeds the %d byte limit" % cap)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as e:
        raise ClientError("cannot open the chosen file: %s" % e.strerror)
    try:
        st2 = os.fstat(fd)
        if not stat.S_ISREG(st2.st_mode):
            raise ClientError("the chosen file is not a regular file")
        if st2.st_size > cap:
            raise ClientError("file exceeds the %d byte limit" % cap)
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > cap:
                raise ClientError("file exceeds the %d byte limit" % cap)
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def read_key_file(path):
    """An enrollment key file: read locally, content never leaves this
    process except inside the request body on the helper's stdin."""
    raw = read_regular_file_bounded(path, MAX_KEYFILE)
    try:
        key = raw.decode("utf-8", "strict").strip()
    except UnicodeDecodeError:
        raise ClientError("key file must contain UTF-8 text") from None
    if key == "":
        raise ClientError("the key file is empty")
    if len(key) > MAX_KEYFILE:
        raise ClientError("key file exceeds the %d byte limit" % MAX_KEYFILE)
    return key


def check_payload_bounds(value, limit=MAX_REQUEST):
    """Reject oversized payload strings before any process is spawned."""
    if isinstance(value, str):
        if len(value) > limit:
            raise ClientError("payload value exceeds the size limit")
    elif isinstance(value, dict):
        total = 0
        for k, v in value.items():
            if not isinstance(k, str) or not is_code(k, 64):
                raise ClientError("payload keys must be short identifiers")
            check_payload_bounds(v, limit)
            total += 1
    elif isinstance(value, list):
        for item in value:
            check_payload_bounds(item, limit)
    elif isinstance(value, (int, float, bool)) or value is None:
        return
    else:
        raise ClientError("payload values must be JSON scalars, objects or arrays")


def wireguard_file_payload(payload):
    """preview/import share one file-carrying shape: the bytes are read
    here and travel base64 inside the request body on the helper's stdin."""
    path = payload.get("path")
    data = read_regular_file_bounded(path, MAX_FILE)
    if path and str(path).lower().endswith(".zip"):
        file_format = "zip"
    elif path and str(path).lower().endswith(".conf"):
        file_format = "conf"
    else:
        raise ClientError("choose a .conf or .zip file")
    payload["format"] = file_format
    payload["data"] = base64.b64encode(data).decode("ascii")
    del payload["path"]
    label = clean_text(payload.get("label", ""), MAX_TEXT)
    if label == "":
        raise ClientError("a display label is required")
    payload["label"] = label
    filename = clean_filename(payload.get("filename", ""))
    if filename == "":
        raise ClientError("the file has no usable name")
    payload["filename"] = filename
    return payload


def prepare_payload(action, payload):
    """Action-specific shaping. Everything the helper requires that the UI
    form cannot be trusted to format is enforced here; the helper still
    re-validates everything independently."""
    if action == "list":
        # The documented scalable protocol: list parameters must SURVIVE
        # this boundary. The backend (cli_connections._LIST_KEYS and
        # store.list_page) accepts exactly offset/limit — exact
        # non-negative integers, booleans and floats refused, limit within
        # 1..MAX_PAGE_LIMIT (4096), unknown fields refused — and applies
        # its own defaults when they are absent. An ordinary list keeps
        # {} here; the client never invents different defaults.
        params = payload or {}
        if not isinstance(params, dict):
            raise ClientError("list parameters must be an object")
        unknown = sorted(set(params) - {"offset", "limit"})
        if unknown:
            raise ClientError("list parameters contain unsupported fields")
        out = {}
        if "offset" in params:
            offset = params["offset"]
            if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
                raise ClientError("offset must be a non-negative integer")
            out["offset"] = offset
        if "limit" in params:
            limit = params["limit"]
            if isinstance(limit, bool) or not isinstance(limit, int) or limit < 0:
                raise ClientError("limit must be a non-negative integer")
            if limit == 0 or limit > 4096:
                raise ClientError("limit must be between 1 and 4096")
            out["limit"] = limit
        return out
    if action in ("preview_wireguard", "import_wireguard"):
        check_payload_bounds({k: v for k, v in payload.items() if k != "data"})
        payload = wireguard_file_payload(payload)
        if action == "import_wireguard":
            policy = payload.get("duplicate_policy")
            if policy not in ("skip", "replace"):
                raise ClientError("an explicit duplicate policy (skip or replace) is required")
            digest = payload.get("digest")
            if not is_code(digest, 128):
                raise ClientError("import requires the reviewed preview digest")
            payload["digest"] = str(digest)
        return payload
    if action == "save":
        cid = payload.get("id")
        if cid is not None:
            # Editing an existing provider: the id is echoed back so the
            # same identity is updated, never a silently new one.
            if not is_code(cid, 128):
                raise ClientError("edit requires a valid connection id")
            payload["id"] = str(cid)
        kind = payload.get("kind")
        if kind not in SAVE_KINDS:
            raise ClientError("unsupported connection kind")
        label = clean_text(payload.get("label", ""), MAX_TEXT)
        if label == "":
            raise ClientError("a display label is required")
        payload["label"] = label
        # Absent settings mean RETAIN (the backend's patch semantics seed
        # unexposed values from the stored record): the client must never
        # fabricate an empty settings object that could be mistaken for a
        # wipe. Only a settings object the panel actually sent travels.
        if "settings" in payload:
            settings = payload.get("settings")
            if not isinstance(settings, dict):
                raise ClientError("settings must be an object")
            payload["settings"] = settings
        else:
            payload.pop("settings", None)
        credentials = payload.get("credentials")
        if credentials is None:
            credentials = {}
        if not isinstance(credentials, dict):
            raise ClientError("credentials must be an object")
        credentials = dict(credentials)
        if not isinstance(credentials.get("clear", []), list):
            raise ClientError("credentials clear must be a list")
        if (kind == "tailscale" and payload.get("settings", {}).get("mode") == "reuse"
                and "authKey" in credentials):
            raise ClientError("host Tailscale reuse does not accept an enrollment key")
        # An enrollment key file is read here so its content never has to
        # pass through QML, argv or the environment.
        key_file = credentials.pop("keyFile", None)
        ca_file = credentials.pop("caCertificateFile", None)
        if ca_file is not None:
            if kind != "headscale" or "caCertificate" in credentials or "caCertificate" in credentials.get("clear", []):
                raise ClientError("choose one Headscale CA certificate source")
            try:
                credentials["caCertificate"] = read_regular_file_bounded(ca_file, 65536).decode("utf-8")
            except UnicodeError:
                raise ClientError("CA certificate must be UTF-8 PEM text") from None
        if key_file is not None:
            if not (kind == "headscale" or kind == "tailscale"
                    and payload.get("settings", {}).get("mode") == "enroll"):
                raise ClientError("key files require Headscale or explicit independent Tailscale enrollment")
            if "authKey" in credentials or "authKey" in credentials.get("clear", []):
                raise ClientError("choose a key file, a pasted key, or clearing the key; do not combine them")
            credentials["authKey"] = read_key_file(key_file)
        if credentials:
            payload["credentials"] = credentials
        check_payload_bounds(payload)
        return payload
    if action == "remove":
        cid = payload.get("id")
        if not is_code(cid, 128):
            raise ClientError("remove requires the connection id")
        payload = {"id": str(cid)}
        return payload
    raise ClientError("unsupported action")  # unreachable: allowlist checked


def build_request(req):
    if not isinstance(req, dict):
        raise ClientError("input is not a JSON object")
    action = req.get("action")
    if action not in ACTIONS:
        raise ClientError("unsupported action")
    request_id = normalize_request_id(req.get("requestId"))
    payload = req.get("payload")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise ClientError("payload must be an object")
    payload = prepare_payload(action, dict(payload))
    body = json.dumps(payload).encode("utf-8")
    if len(body) > MAX_REQUEST:
        raise ClientError("request exceeds the %d byte limit" % MAX_REQUEST)
    request = {"version": VERSION, "request_id": request_id,
               "action": action, "payload": payload}
    revision = req.get("revision")
    if revision is not None:
        # Exact types only: revision 0 is a real store state and must be
        # carried, while a quoted "7", a bool, a float or a negative is
        # REFUSED here — never silently dropped (a revision-less mutation
        # would only fail later at the helper) and never coerced into a
        # number that merely looks right.
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
            raise ClientError("the revision must be a non-negative integer")
        request["revision"] = revision
    return request


def normalize_request_id(value):
    """The request id the whole exchange answers under, normalized once so
    every later echo matches: None or blank becomes a generated id, other
    values are coerced to text and stripped; anything with control bytes or
    over the length cap is refused. The same normalized id goes into the
    helper request, every locally generated error envelope, and the final
    response — the panel matches on exactly this value."""
    if value is None:
        return "req-" + uuid.uuid4().hex
    v = str(value).strip()
    if v == "":
        return "req-" + uuid.uuid4().hex
    if not is_code(v, 64):
        raise ClientError("requestId must be a short identifier")
    return v


def helper_command():
    """The one authorized invocation. Fixed absolute helper path, fixed
    verb, no shell, nothing user-derived in argv."""
    return ["sudo", "-n", HELPER, HELPER_VERB]


def validate_response(value, expected_request_id=None):
    if not isinstance(value, dict):
        raise ClientError("response is not a JSON object")
    if value.get("version") != VERSION:
        raise ClientError("response version mismatch")
    if expected_request_id and value.get("request_id") != expected_request_id:
        raise ClientError("response does not match the request")
    if not isinstance(value.get("ok"), bool):
        raise ClientError("response carries no ok field")
    if value["ok"]:
        if not isinstance(value.get("data"), dict):
            raise ClientError("ok response carries no data object")
    else:
        err = value.get("error")
        if not isinstance(err, dict) or not isinstance(err.get("code"), str):
            raise ClientError("error response is not in the contract shape")
    return value


def _kill_own_child(proc):
    """Kill OUR direct child only. Never a process group or any other
    process — the child here is the helper invocation this function
    started, and nothing else may ever be signaled from this client."""
    try:
        proc.kill()
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # The direct child refused to die within the bound; report and move
        # on rather than blocking forever on our own process table.
        pass


def run_helper(request_bytes, command=None, timeout=HELPER_TIMEOUT):
    """Send the request on the helper's stdin, read a bounded response.

    Bounded while reading, not afterwards: stdout is capped at
    MAX_RESPONSE + 1 bytes and stderr at MAX_STDERR bytes as the bytes
    arrive (extra stderr is drained and discarded so the pipe cannot back
    up), all under one overall monotonic deadline. A child that overruns
    the deadline or the output cap is killed — our own direct child only,
    never a group. A helper that writes nothing and exits nonzero reads as
    "not installed / not authorized" upstream of this function.

    Returns (stdout_bytes, stderr_bytes, returncode).
    """
    argv = helper_command() if command is None else list(command)
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as e:
        raise ClientError("cannot start the connections helper: %s" % e.strerror)
    except OSError as e:
        raise ClientError("cannot start the connections helper: %s" % e.strerror)

    deadline = time.monotonic() + max(0.1, float(timeout))
    sel = selectors.DefaultSelector()
    streams = {"stdin": proc.stdin, "stdout": proc.stdout, "stderr": proc.stderr}
    for s in streams.values():
        os.set_blocking(s.fileno(), False)
    view = memoryview(request_bytes)
    written = 0
    out = bytearray()
    err = bytearray()
    stdout_over = False
    stdin_done = len(view) == 0

    def remaining():
        return deadline - time.monotonic()

    def drop(stream):
        try:
            sel.unregister(stream)
        except (KeyError, ValueError):
            pass
        try:
            stream.close()
        except OSError:
            pass

    try:
        sel.register(streams["stdout"], selectors.EVENT_READ)
        sel.register(streams["stderr"], selectors.EVENT_READ)
        if not stdin_done:
            sel.register(streams["stdin"], selectors.EVENT_WRITE)
        while True:
            left = remaining()
            if left <= 0:
                _kill_own_child(proc)
                raise ClientError("the connections helper did not answer in time")
            for key, events in sel.select(left):
                stream = key.fileobj
                try:
                    if stream is streams["stdin"] and events & selectors.EVENT_WRITE:
                        n = os.write(stream.fileno(), view[written:written + 65536])
                        written += n
                        if written >= len(view):
                            stdin_done = True
                            drop(stream)
                    elif stream is streams["stdout"] and events & selectors.EVENT_READ:
                        chunk = os.read(stream.fileno(), 65536)
                        if not chunk:
                            drop(stream)
                        else:
                            out.extend(chunk)
                            if len(out) > MAX_RESPONSE:
                                stdout_over = True
                    elif stream is streams["stderr"] and events & selectors.EVENT_READ:
                        chunk = os.read(stream.fileno(), 65536)
                        if not chunk:
                            drop(stream)
                        elif len(err) < MAX_STDERR:
                            err.extend(chunk[:MAX_STDERR - len(err)])
                        # Else: drained and discarded — bounded memory.
                except (OSError, ValueError):
                    # The child closed the pipe; stop watching that stream.
                    drop(stream)
                if stdout_over:
                    break
            if stdout_over:
                _kill_own_child(proc)
                raise ClientError("helper response exceeds the %d byte limit" % MAX_RESPONSE)
            if not list(sel.get_map()):
                break
        code = proc.wait(timeout=max(0.1, remaining()))
        return bytes(out), bytes(err), code
    except ClientError:
        raise
    except subprocess.TimeoutExpired:
        _kill_own_child(proc)
        raise ClientError("the connections helper did not answer in time")
    finally:
        sel.close()
        for s in streams.values():
            try:
                if not s.closed:
                    s.close()
            except OSError:
                pass
        if proc.poll() is None:
            _kill_own_child(proc)


def emit(write, payload):
    write(json.dumps(payload) + "\n")


def error_envelope(code, message, request_id=""):
    """A locally generated response in the SAME contract shape the helper
    speaks: version 1, the request id the panel asked under, ok false, and
    a bounded error object. The panel's parser keys state off these fields
    (helper-unavailable → "unavailable"), so a local failure must never be
    a shapeless dict."""
    return {"version": VERSION, "request_id": request_id or "", "ok": False,
            "error": {"code": code, "message": sanitize_message(message)}}


def usable_revision(value):
    """A committed store revision: an exact non-negative integer."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def private_host_sync_pending(action, prepared_payload):
    """The smallest automatic private-host lifecycle: a committed Headscale
    save carries private_hosts entries and every committed remove may drop
    them, so exactly those successful mutations are followed by one
    explicit sync_private_hosts request. Nothing else chains."""
    if action == "remove":
        return True
    return (action == "save" and isinstance(prepared_payload, dict)
            and prepared_payload.get("kind") == "headscale")


def build_sync_request(committed_revision):
    """The internal follow-up request. It carries ONLY the freshly
    generated internal request id, the sync action, the committed revision
    and an empty payload — never credentials, never any part of the
    original payload, never the panel's request id."""
    return {"version": VERSION, "request_id": normalize_request_id(None),
            "action": SYNC_PRIVATE_HOSTS, "payload": {},
            "revision": committed_revision}


def run_private_host_sync(committed_revision, command=None):
    """One fixed-helper sync request under the same bounded runner and
    response contract as the first call. Returns None when the sync is
    confirmed; otherwise a sanitized, bounded failure hint — never request
    or secret bytes."""
    sync_request = build_sync_request(committed_revision)
    try:
        out, _err, _code = run_helper(
            json.dumps(sync_request).encode("utf-8"), command)
    except ClientError as e:
        return str(e)
    if not out.strip():
        return "the connections helper did not answer the sync request"
    try:
        sync_response = validate_response(json.loads(out.decode("utf-8")),
                                          sync_request["request_id"])
    except (UnicodeDecodeError, ValueError):
        return "the sync response is not valid JSON"
    except ClientError as e:
        return str(e)
    if sync_response.get("ok") is not True:
        err = sync_response.get("error")
        detail = err.get("code") if isinstance(err, dict) else ""
        return "the sync request was refused" + (
            " (%s)" % sanitize_message(detail) if is_code(detail, 64) else "")
    return None


def host_sync_required_envelope(request_id, committed_revision, reason):
    """The truthful failure shape: the catalog change IS committed — no
    rollback is claimed or attempted — while private hostname
    synchronization still needs a retry or administrator review. The
    committed revision travels only because the current response contract
    carries a top-level revision on helper replies."""
    envelope = error_envelope(
        "host-sync-required",
        "the catalog change was saved, but private hostname synchronization "
        "needs a retry or administrator review: " + sanitize_message(reason),
        request_id)
    if usable_revision(committed_revision):
        envelope["revision"] = committed_revision
    return envelope


def main(argv=None, stdin_bytes=None, command=None, write=None):
    if write is None:
        write = sys.stdout.write
    request_id = ""
    try:
        if stdin_bytes is None:
            stdin_bytes = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(stdin_bytes) > MAX_INPUT:
            raise ClientError("input exceeds the %d byte limit" % MAX_INPUT)
        try:
            req = json.loads(stdin_bytes.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ClientError("input is not valid JSON")
        if isinstance(req, dict) and req.get("requestId") is not None:
            try:
                request_id = normalize_request_id(req.get("requestId"))
            except ClientError:
                request_id = ""
        request = build_request(req)
        request_id = request["request_id"]
        body = json.dumps(request).encode("utf-8")
    except ClientError as e:
        emit(write, error_envelope("input", e, request_id))
        return EXIT_INPUT

    try:
        out, err, code = run_helper(body, command)
    except ClientError as e:
        emit(write, error_envelope("helper-unavailable", e, request_id))
        return EXIT_HELPER_MISSING

    if out.strip():
        try:
            response = validate_response(json.loads(out.decode("utf-8")),
                                         request_id)
        except (UnicodeDecodeError, ValueError):
            emit(write, error_envelope("contract",
                                       "helper response is not valid JSON", request_id))
            return EXIT_CONTRACT
        except ClientError as e:
            emit(write, error_envelope("contract", e, request_id))
            return EXIT_CONTRACT
        if (response.get("ok") is True
                and private_host_sync_pending(request["action"], request["payload"])):
            committed = response.get("revision")
            if not usable_revision(committed):
                # A committed Headscale save/remove whose answer carries no
                # exact non-negative integer revision can never form a safe
                # follow-up: no revision is invented, the helper is NOT
                # called a second time, and the mutation must not be
                # reported as a clean success.
                emit(write, host_sync_required_envelope(
                    request_id, None,
                    "the helper's answer carries no committed revision, so "
                    "private hostname synchronization could not be issued"))
                return EXIT_OK
            # One automatic follow-up for the committed mutation. The panel
            # never sees the internal sync exchange: success emits the
            # original response unchanged, failure emits the truthful
            # host-sync-required envelope under the ORIGINAL request id.
            failure = run_private_host_sync(committed, command)
            if failure is not None:
                emit(write, host_sync_required_envelope(
                    request_id, committed, failure))
                return EXIT_OK
        emit(write, response)
        return EXIT_OK

    if code != 0:
        # Nothing on stdout: the helper never answered. sudo's own failure
        # (not installed, not authorized) lands here; its stderr names the
        # fixed command only — never request or secret bytes.
        hint = sanitize_message(err.decode("utf-8", "replace"))[:120]
        emit(write, error_envelope(
            "helper-unavailable",
            "connections backend unavailable" + (": " + hint if hint else ""),
            request_id))
        return EXIT_HELPER_MISSING

    emit(write, error_envelope("contract", "helper produced no response", request_id))
    return EXIT_CONTRACT


if __name__ == "__main__":
    sys.exit(main())
