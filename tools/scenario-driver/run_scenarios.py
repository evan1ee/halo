#!/usr/bin/env python3
"""Server half of the read-state scenarios S01–S22 (docs/testing/UNREAD_REGRESSION_TESTS.md §3) against the dev homeserver.

What it checks: with real devices (own sync token each, own receipts), what the server serves a device after incremental syncs,
limited timelines, a second device's receipts, marked-unread and mute. Those are the inputs the client-side model in
HaloApplicationTests/ReadStateScenarioTests.swift assumes. Client behaviour (policy, outbox, restarts) is not run here.
Needs infra/dev up and Docker (users via register_new_matrix_user). Creates throwaway users per run.
Fault cases F01–F06 (ROADMAP M17-6) need the fault proxy between the devices and the server, so they run only through
`infra/test/run.sh scenarios`, which also starts a throwaway server; otherwise they are listed as skipped. A device that misbehaves on
purpose (HALO_SCENARIO_BREAK=retry|txn) must make them fail: that is how they are checked to be able to.
Usage: tools/scenario-driver/run_scenarios.py [S04 F02 …]    (HALO_DEV_SERVER overrides http://localhost:8008)
Exit status 1 if the server disagrees with the model; the report names each scenario and what it observed."""
import http.client, json, os, secrets, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, uuid

B = os.environ.get("HALO_DEV_SERVER", "http://localhost:8008") + "/_matrix/client/v3"
PW = secrets.token_hex(12)  # throwaway, local dev server only
q = urllib.parse.quote


def req(method, path, token=None, body=None):
    r = urllib.request.Request(B + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"content-type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(r, timeout=60) as f:
                return json.load(f)
        except urllib.error.HTTPError as e:
            body = json.load(e)
            if e.code == 429 and attempt < 7:  # rate limited: wait as told
                time.sleep(min(body.get("retry_after_ms", 1000), 5000) / 1000)
                continue
            return {"_err": e.code, **body}


def login(name):
    d = req("POST", "/login", None, {"type": "m.login.password", "identifier": {"type": "m.id.user", "user": name}, "password": PW,
                                     "initial_device_display_name": "scenario"})
    return d["access_token"], d["user_id"]


def register(name):
    subprocess.run(["docker", "exec", "-i", os.environ.get("HALO_DEV_SYNAPSE_CONTAINER", "halo-dev-synapse-1"), "register_new_matrix_user", "-c", "/data/homeserver.yaml", "-u", name,
                    "--password-file", "/dev/stdin", "--no-admin", "--exists-ok", "http://localhost:8008"],
                   input=PW.encode(), capture_output=True, check=True)


class Device:
    """One logged-in device with its own sync position, like A1 or A2."""
    def __init__(s, name, limit=None):
        s.tok, s.id = login(name)
        s.since, s.rooms, s.limit = None, {}, limit

    def sync(s):
        filt = q(json.dumps({"room": {"timeline": {"limit": s.limit}}})) if s.limit else ""
        path = "/sync?timeout=0" + (f"&since={s.since}" if s.since else "") + (f"&filter={filt}" if filt else "")
        d = req("GET", path, s.tok)
        s.since = d["next_batch"]
        for rid, r in d.get("rooms", {}).get("join", {}).items():
            cur = s.rooms.setdefault(rid, {"n": 0, "h": 0, "limited": False, "marked_unread": None})
            if "unread_notifications" in r:
                cur["n"] = r["unread_notifications"].get("notification_count", cur["n"])
                cur["h"] = r["unread_notifications"].get("highlight_count", cur["h"])
            cur["limited"] = r.get("timeline", {}).get("limited", False)
            for ev in r.get("account_data", {}).get("events", []):
                if ev["type"] == "m.marked_unread":
                    cur["marked_unread"] = ev["content"].get("unread")
        return d

    def counts(s, room):
        s.sync()
        c = s.rooms.get(room, {})
        return c.get("n", 0), c.get("h", 0)

    def send(s, room, body, extra=None):
        c = {"msgtype": "m.text", "body": body, **(extra or {})}
        return req("PUT", f"/rooms/{q(room)}/send/m.room.message/{uuid.uuid4().hex}", s.tok, c)["event_id"]

    def read(s, room, ev):
        req("POST", f"/rooms/{q(room)}/receipt/m.read/{q(ev)}", s.tok, {})


sfx = uuid.uuid4().hex[:5]
for n in ("a", "b"):
    register(f"scen_{n}{sfx}")
A1, A2 = Device(f"scen_a{sfx}", limit=5), Device(f"scen_a{sfx}")  # A1 syncs with small timelines (limited gaps)
Bx = Device(f"scen_b{sfx}")
mention = lambda: {"m.mentions": {"user_ids": [A1.id]}}


def room():
    d = req("POST", "/createRoom", A1.tok, {"preset": "public_chat"})
    for _ in range(5):
        if "room_id" in d: break
        time.sleep(d.get("retry_after_ms", 1000) / 1000); d = req("POST", "/createRoom", A1.tok, {"preset": "public_chat"})
    r = d["room_id"]
    req("POST", f"/join/{q(r)}", Bx.tok, {})
    return r


results = []
def check(sid, what, got, want): results.append((sid, what, got, want))


def s01():
    r = room(); evs = [Bx.send(r, f"m{i}") for i in range(5)]
    check("S01", "5 unread from B", A1.counts(r), (5, 0))
    A1.read(r, evs[-1]); check("S01", "receipt at the 5th: counts 0", A1.counts(r), (0, 0))


def s02():
    r = room(); evs = [Bx.send(r, f"m{i}") for i in range(5)]
    A1.sync(); check("S02", "A1 sees 5", A1.counts(r), (5, 0))
    A2.read(r, evs[-1]); check("S02", "A2's receipt reaches A1 within one incremental sync", A1.counts(r), (0, 0))


def s04():
    rooms = [room() for _ in range(20)]; last = {}
    A1.sync()
    for _ in range(15):
        for r in rooms: last[r] = Bx.send(r, "x")
    for r in rooms[:10]: A2.read(r, last[r])
    A1.sync()
    got = sorted(i for i, r in enumerate(rooms) if A1.rooms.get(r, {}).get("n", 0) > 0)
    check("S04", "300 messages, limited timelines; A2 read rooms 0–9", got, list(range(10, 20)))
    check("S04", "the counts of an unread room are exact despite the gap", A1.rooms[rooms[10]]["n"], 15)


def s05():
    r = room(); A1.sync()
    evs = [Bx.send(r, f"m{i}") for i in range(12)]
    A2.read(r, evs[3])  # inside the gap A1 will not receive (limit 5)
    A1.sync()
    check("S05", "limited timeline, receipt inside the gap: timeline is limited", A1.rooms[r]["limited"], True)
    check("S05", "server counts only the events after A2's receipt", (A1.rooms[r]["n"], A1.rooms[r]["h"]), (8, 0))
    A2.read(r, evs[-1]); check("S05", "a receipt at the latest event: 0", A1.counts(r), (0, 0))


def s09():
    r = room(); A1.sync()
    req("PUT", f"/user/{q(A2.id)}/rooms/{q(r)}/account_data/m.marked_unread", A2.tok, {"unread": True})
    A1.sync(); check("S09", "A1 receives m.marked_unread=true", A1.rooms[r]["marked_unread"], True)
    check("S09", "marking unread leaves the counts at 0", A1.counts(r), (0, 0))
    req("PUT", f"/user/{q(A1.id)}/rooms/{q(r)}/account_data/m.marked_unread", A1.tok, {"unread": False})
    A2.sync(); A2.sync(); check("S09", "clearing on A1 reaches A2", A2.rooms[r]["marked_unread"], False)


def s10():
    r = room(); [Bx.send(r, f"m{i}") for i in range(4)]
    check("S10", "4 unread before muting", A1.counts(r), (4, 0))
    req("PUT", f"/pushrules/global/override/{q(r)}", A2.tok, {"conditions": [{"kind": "event_match", "key": "room_id", "pattern": r}], "actions": []})
    Bx.send(r, "after mute")
    check("S10", "mute stops new counting; existing counts stay (the client must hide them: E-mute)", A1.counts(r), (4, 0))


def s14():
    r = room(); root = Bx.send(r, "root"); A1.read(r, root); A1.sync()
    Bx.send(r, "reply", {"m.relates_to": {"rel_type": "m.thread", "event_id": root}})
    check("S14", "a thread reply counts", A1.counts(r), (1, 0))
    last = Bx.send(r, "reply2", {"m.relates_to": {"rel_type": "m.thread", "event_id": root}})
    A1.read(r, last); check("S14", "an unthreaded receipt at the last thread reply clears it", A1.counts(r), (0, 0))


def s15():
    r = room(); e = Bx.send(r, "orig"); A1.read(r, e); A1.sync()
    Bx.send(r, "* edit", {"m.new_content": {"msgtype": "m.text", "body": "edit"}, "m.relates_to": {"rel_type": "m.replace", "event_id": e}})
    check("S15", "an edit of a read message adds no count", A1.counts(r), (0, 0))


def s22():
    r = room(); req("PUT", f"/pushrules/global/room/{q(r)}", A1.tok, {"actions": []}); A1.sync()
    for i in range(30): Bx.send(r, f"m{i}", mention() if i == 7 else None)
    A1.sync()
    check("S22", "unencrypted mentions-only, limited timeline: the server still counts the mention", (A1.rooms[r]["n"], A1.rooms[r]["h"]), (1, 1))
    check("S22", "the timeline is limited, the mention is in the gap", A1.rooms[r]["limited"], True)


def mentions_only(r, dev):
    req("PUT", f"/pushrules/global/room/{q(r)}", dev.tok, {"actions": []})


def enc_room():
    r = room()
    req("PUT", f"/rooms/{q(r)}/state/m.room.encryption", A1.tok, {"algorithm": "m.megolm.v1.aes-sha2"})
    return r


def enc_send(dev, r, mentions_a=False):
    # Opaque ciphertext: the server cannot read the content, so it cannot see m.mentions either.
    c = {"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": secrets.token_hex(16), "device_id": "x", "sender_key": "x", "session_id": "x"}
    return req("PUT", f"/rooms/{q(r)}/send/m.room.encrypted/{uuid.uuid4().hex}", dev.tok, c)["event_id"]


def s06():
    r = enc_room(); A1.sync(); enc_send(Bx, r)
    check("S06", "encrypted room, all-messages: the server counts the opaque event", A1.counts(r), (1, 0))


def s07():
    r = enc_room(); mentions_only(r, A1); A1.sync()
    for _ in range(3): enc_send(Bx, r)
    check("S07", "encrypted mentions-only, 3 messages: the server counts nothing (client falls back to SDK counts)", A1.counts(r), (0, 0))


def s07b():
    r = room(); mentions_only(r, A1); A1.sync()
    evs = [Bx.send(r, f"m{i}") for i in range(3)]
    check("S07b", "unencrypted mentions-only, 3 plain messages: server counts 0", A1.counts(r), (0, 0))
    A1.read(r, evs[-1]); check("S07b", "after viewing and a receipt: still 0", A1.counts(r), (0, 0))


def s08():
    r = room(); A1.sync(); e = Bx.send(r, "oops")
    check("S08", "one unread message", A1.counts(r), (1, 0))
    req("PUT", f"/rooms/{q(r)}/redact/{q(e)}/{uuid.uuid4().hex}", Bx.tok, {})
    check("S08", "the only unread message is redacted: server count drops to 0", A1.counts(r), (0, 0))


def s13():
    r = room(); [Bx.send(r, f"m{i}") for i in range(3)]
    check("S13", "3 unread", A1.counts(r), (3, 0))
    A1.send(r, "my reply")
    check("S13", "own message does not reset the server counts (the client clears via E1b)", A1.counts(r), (3, 0))


def s21():
    r = enc_room(); mentions_only(r, A1); A1.sync()
    enc_send(Bx, r)
    check("S21", "encrypted mentions-only, a (hidden) mention: the server counts 0 (SERVER_BLIND)", A1.counts(r), (0, 0))


# MARK: Fault cases (through infra/test's proxy)

CONTROL, BREAK = os.environ.get("HALO_TEST_CONTROL"), os.environ.get("HALO_SCENARIO_BREAK", "")


def fault(**rule):
    r = urllib.request.Request(CONTROL + "/rules", method="POST", data=json.dumps(rule).encode())
    with urllib.request.urlopen(r, timeout=5) as f:
        return json.load(f)["id"]


def heal():
    urllib.request.urlopen(urllib.request.Request(CONTROL + "/rules", method="DELETE"), timeout=5).close()


def raw(method, path, token, body=None, timeout=20):
    """One attempt, no retries: (status or None when no answer came, answer)."""
    r = urllib.request.Request(B + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"content-type": "application/json", "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as f:
            return f.status, json.load(f)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)
    except (OSError, http.client.HTTPException, ValueError):
        return None, {}


def persist(method, path, token, body=None, timeout=20, seconds=20):
    """What a correct client does: the same request again until it is answered, waiting as told after 429."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        code, answer = raw(method, path, token, body, timeout)
        if code == 200 or BREAK == "retry":
            return code, answer
        time.sleep(answer.get("retry_after_ms", 250) / 1000)
    return None, {}


def send_persistently(dev, r, text, timeout=20):
    first = path = f"/rooms/{q(r)}/send/m.room.message/{uuid.uuid4().hex}"
    body = {"msgtype": "m.text", "body": text}
    code, answer = raw("PUT", first, dev.tok, body, timeout)
    if code == 200:
        return answer["event_id"]
    if BREAK == "retry":
        return None
    time.sleep(answer.get("retry_after_ms", 250) / 1000)
    if BREAK == "txn":  # a client that makes up a new transaction ID for every attempt
        path = f"/rooms/{q(r)}/send/m.room.message/{uuid.uuid4().hex}"
    return persist("PUT", path, dev.tok, body, timeout)[1].get("event_id")


def bodies(r):
    d = req("GET", f"/rooms/{q(r)}/messages?dir=b&limit=100", A2.tok)
    return [e["content"].get("body") for e in reversed(d["chunk"]) if e["type"] == "m.room.message"]


def f01():
    r = room(); A1.sync()
    number = fault(action="refuse")
    code, _ = raw("GET", "/sync?timeout=0", A1.tok)
    check("F01", "the server is down: no answer", code, None)
    heal(); Bx.send(r, "while away"); check("F01", "back: the same sync position brings what was missed", A1.counts(r), (1, 0))


def f02():
    r = room()
    fault(action="lose", path="/send/", times=1)
    event = send_persistently(A1, r, "lost answer"); heal()
    check("F02", "the answer was lost, the retry has the same transaction: one message, the same event", (bodies(r), event is not None), (["lost answer"], True))


def f03():
    r = room()
    fault(action="status", status=429, retry_after_ms=400, path="/send/", times=2)
    started = time.monotonic(); send_persistently(A1, r, "limited"); waited = time.monotonic() - started; heal()
    check("F03", "rate limited twice: sent once, after the waits it was told", (bodies(r), waited >= 0.8), (["limited"], True))


def f04():
    r = room(); A1.sync(); Bx.send(r, "x")
    fault(action="cut", bytes=20, path="/sync", times=1)
    path = f"/sync?timeout=0&since={A1.since}"
    code, answer = raw("GET", path, A1.tok)
    check("F04", "the sync response breaks off: nothing usable", code, None)
    fault(action="cut", bytes=20, path="/sync", times=1)
    code, answer = persist("GET", path, A1.tok); heal()
    check("F04", "the same position again delivers the whole response", r in answer.get("rooms", {}).get("join", {}), True)


def f05():
    r = room(); A1.sync(); Bx.send(r, "y")
    fault(action="hang", path="/sync", times=1)
    started = time.monotonic(); code, answer = persist("GET", f"/sync?timeout=0&since={A1.since}", A1.tok, timeout=2); took = time.monotonic() - started; heal()
    check("F05", "half-open connection: given up after its timeout, then delivered", (r in answer.get("rooms", {}).get("join", {}), took < 6), (True, True))


def f06():
    r = room()
    fault(action="status", status=503, path="/send/", times=1)
    for number in range(3):
        send_persistently(A1, r, f"m{number}")
    heal()
    check("F06", "a server error on the first of three: all once and in order", bodies(r), ["m0", "m1", "m2"])


ALL = {k.upper(): v for k, v in globals().items() if k[0] in "sf" and k[1:3].isdigit() and callable(v)}
want = [a.upper() for a in sys.argv[1:]] or sorted(ALL)
if not CONTROL:
    skipped = [s for s in want if s.startswith("F")]
    want = [s for s in want if s not in skipped]
    if skipped: print("skip " + " ".join(skipped) + " (need the fault proxy: infra/test/run.sh scenarios)")
for sid in want:
    ALL[sid]()
bad = [x for x in results if x[2] != x[3]]
for sid, what, got, exp in results:
    print(("ok   " if got == exp else "FAIL ") + f"{sid} {what}: got {got}, expected {exp}")
sys.exit(1 if bad else 0)
