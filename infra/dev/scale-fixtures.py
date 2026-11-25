#!/usr/bin/env python3
"""Large accounts on a server of their own, to measure Halo at scale (ROADMAP M17-3/M17-4).

    infra/dev/scale-fixtures.py up        # start the server and create what is missing; run again after an interruption
    infra/dev/scale-fixtures.py status    # what exists
    infra/dev/scale-fixtures.py down      # stop it, keep the data (`up` continues)
    infra/dev/scale-fixtures.py remove --yes   # delete server, data and settings. Can't be undone

It is a separate compose project (halo-scale, http://localhost:8108, server name scale.halo.localhost); it never talks to the shared dev
server on port 8008. Passwords and tokens are generated into ~/.config/halo-dev/scale/ (mode 600; $HALO_SCALE_DIR) and never printed.

Accounts (see PLAN): `scale300` and `scale1000` have 300 and 1,000 rooms, the first 300 shared: 60 % direct chats, 30 % with 10 members, 8 %
with 50, 2 % with 200, each with 30 messages over the last 90 days and a third of them unread. `scalebig` has a room with 10,000 members and a
room with 20,000 events, every second one an image. `scaleprobe` is in all of `scale1000`'s rooms and writes what the incremental measurements need.
HALO_SCALE_QUICK=1 makes a tenth of everything, to try the script.
"""
import concurrent.futures, json, os, random, secrets, struct, subprocess, sys, tempfile, threading, time, urllib.error, urllib.parse, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ.get("HALO_SCALE_DIR", os.path.expanduser("~/.config/halo-dev/scale"))
PORT = int(os.environ.get("HALO_SCALE_PORT", "8108"))
SERVER, NAME = f"http://localhost:{PORT}", "scale.halo.localhost"
if PORT == 8008:
    raise SystemExit("port 8008 is the shared dev server")
Q = 10 if os.environ.get("HALO_SCALE_QUICK") == "1" else 1
ROOMS, SMALL_ROOMS, BIG_MEMBERS, MEDIA_EVENTS, MESSAGES = 1000 // Q, 300 // Q, 10_000 // Q, 20_000 // Q, 30
ACCOUNTS = ["scale300", "scale1000", "scalebig", "scaleprobe"]
DAY = 86_400_000


# MARK: Settings

def path(name): return os.path.join(DIR, name)


def private_write(name, text):
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    fd = os.open(path(name) + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(path(name) + ".new", path(name))


def load(name, default):
    try:
        return json.load(open(path(name)))
    except FileNotFoundError:
        return default


class State:
    """What is done, so an interrupted run continues. Saved after every room."""

    def __init__(self):
        self.values, self.lock = load("state.json", {}), threading.Lock()

    def get(self, key, default=None): return self.values.get(key, default)

    def set(self, key, value):
        with self.lock:
            self.values[key] = value
            private_write("state.json", json.dumps(self.values))


# MARK: HTTP

class Failed(Exception):
    def __init__(self, status, body):
        super().__init__(f"{status} {body[:200]!r}")
        self.status = status
        self.errcode = (json.loads(body) if body.startswith(b"{") else {}).get("errcode")


def call(method, route, body=None, token=None, raw=None, ctype="application/json", user=None, ts=None):
    query = {k: v for k, v in (("user_id", user), ("ts", ts)) if v is not None}
    url = SERVER + route + ("&" if "?" in route else "?") + urllib.parse.urlencode(query) if query else SERVER + route
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", ctype)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            failure = Failed(error.code, error.read())
            if (error.code < 500 and error.code != 429) or attempt == 5:
                raise failure
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            if attempt == 5:
                raise
        time.sleep(1 << attempt)


def compose(*arguments, **options):
    # The Docker CLI's default credential helper can hang, and a config without it has no compose plugin: keep the plugin only.
    env = dict(os.environ, HALO_SCALE_DIR=DIR, HALO_SCALE_PORT=str(PORT))
    return subprocess.run(["docker", "compose", "-f", os.path.join(HERE, "docker-compose.scale.yml"), *arguments], env=env, check=True, **options)


# MARK: Server and accounts

def start():
    appservice = load("appservice.json", None)
    if appservice is None:
        appservice = {"as_token": secrets.token_hex(32), "hs_token": secrets.token_hex(32)}
        private_write("appservice.json", json.dumps(appservice))
    # JSON is YAML. No URL: Synapse never calls back.
    private_write("appservice.yaml", json.dumps({
        "id": "halo-scale", "url": None, **appservice, "sender_localpart": "scalebot", "rate_limited": False,
        "namespaces": {"users": [{"exclusive": True, "regex": f"@m-[0-9]+:{NAME}"}], "rooms": [], "aliases": []}}))
    os.chmod(path("appservice.yaml"), 0o644)  # Synapse runs as another user in the container; the folder itself is private
    compose("up", "-d", "--wait", "--quiet-pull")
    return appservice["as_token"]


def user_id(localpart): return f"@{localpart}:{NAME}"


def accounts(state):
    """Password accounts people (and Halo) sign in to; returns their tokens for this run."""
    passwords = load("passwords.json", {})
    for name in ACCOUNTS:
        if name not in passwords:
            passwords[name] = secrets.token_urlsafe(18)
            private_write("passwords.json", json.dumps(passwords))
        if not state.get(f"account {name}"):
            subprocess.run(["docker", "exec", "-i", "halo-scale-synapse-1", "register_new_matrix_user", "-c", "/data/homeserver.yaml", "-u", name,
                            "--password-file", "/dev/stdin", "--no-admin", "--exists-ok", "http://localhost:8008"],
                           input=passwords[name].encode(), check=True, stdout=subprocess.DEVNULL, timeout=120)
            state.set(f"account {name}", True)
    return {name: call("POST", "/_matrix/client/v3/login", {
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": name}, "password": passwords[name],
        "initial_device_display_name": "scale fixtures"})["access_token"] for name in ACCOUNTS}


def members(token, state, count):
    """@m-0…: application-service users (no password, so creating one costs milliseconds)."""
    done = state.get("members", 0)
    def make(index):
        try:
            call("POST", "/_matrix/client/v3/register", {"type": "m.login.application_service", "username": f"m-{index}", "inhibit_login": True}, token)
        except Failed as error:
            if error.errcode != "M_USER_IN_USE":
                raise
    with concurrent.futures.ThreadPoolExecutor(12) as pool:
        while done < count:
            batch = range(done, min(done + 500, count))
            list(pool.map(make, batch))
            done = batch.stop
            state.set("members", done)
            print(f"  members {done}/{count}", flush=True)


# MARK: Rooms

WORDS = "ok yes later today meeting lunch photo draft build release coffee weekend train ticket review notes ship garden music plan".split()


def text(rng): return " ".join(rng.choices(WORDS, k=rng.randint(2, 14)))


def join(token, room, user):
    call("POST", f"/_matrix/client/v3/rooms/{urllib.parse.quote(room)}/join", {}, token, user=user)


def members_of(index):
    """How many people are in room `index`: the mix of every block of 50 is the same, so the first 300 rooms are a smaller copy of the 1,000."""
    slot = index % 50
    return 2 if slot < 30 else 10 if slot < 45 else 50 if slot < 49 else 200


def people_of(index, state):
    """The other members of room `index`, its owner first."""
    size = max(2, members_of(index) // (Q if members_of(index) > 10 else 1))
    return [user_id(f"m-{n}") for n in random.Random(index).sample(range(state.get("members")), size - 1)]


def make_room(index, token, state, tokens):
    key = f"room {index}"
    if state.get(f"done {index}"):
        return
    rng = random.Random(index + 1_000_000)
    people = people_of(index, state)
    owner, direct = people[0], len(people) == 1
    # Direct chats and every second group are encrypted rooms (their messages here aren't), so the SDK has devices to look up.
    encrypted = direct or (len(people) == 9 and index % 2 == 0)
    room = state.get(key)
    if room is None:
        body = {"preset": "public_chat", "is_direct": direct}
        if not direct:
            body |= {"name": f"Scale {index:04d} {rng.choice(WORDS)}", "topic": text(rng)}
        if encrypted:
            body["initial_state"] = [{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}]
        room = call("POST", "/_matrix/client/v3/createRoom", body, token, user=owner)["room_id"]
        state.set(key, room)
    for person in people[1:]:
        join(token, room, person)
    watchers = ["scaleprobe", "scale1000"] + (["scale300"] if index < SMALL_ROOMS else [])
    for name in watchers:
        join(tokens[name], room, None)
    newest, last = int(time.time() * 1000) - rng.randint(0, 60) * DAY, None
    for number in range(MESSAGES):
        event = call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/r{index}-{number}", {"msgtype": "m.text", "body": text(rng)},
                     token, user=rng.choice(people), ts=newest - (MESSAGES - number) * 3_600_000)["event_id"]
        if number == MESSAGES - 1 - (5 if index % 3 == 0 else 0):  # a third of the rooms have five unread messages
            last = event
    for name in watchers:
        call("POST", f"/_matrix/client/v3/rooms/{room}/receipt/m.read/{urllib.parse.quote(last)}", {}, tokens[name])
    state.set(f"done {index}", True)


def small_rooms(token, state, tokens):
    todo = [i for i in range(ROOMS) if not state.get(f"done {i}")]
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        for count, _ in enumerate(pool.map(lambda i: make_room(i, token, state, tokens), todo), 1):
            if count % 50 == 0:
                print(f"  rooms {ROOMS - len(todo) + count}/{ROOMS}", flush=True)
    for name in ("scale300", "scale1000"):  # the account's own list of direct chats, as a client would have written it
        chats = {}
        for index in range(SMALL_ROOMS if name == "scale300" else ROOMS):
            if members_of(index) == 2:
                chats.setdefault(people_of(index, state)[0], []).append(state.get(f"room {index}"))
        call("PUT", f"/_matrix/client/v3/user/{user_id(name)}/account_data/m.direct", chats, tokens[name])


def big_room(token, state, tokens):
    room = state.get("big")
    if room is None:
        room = call("POST", "/_matrix/client/v3/createRoom", {"preset": "public_chat", "name": "Ten thousand members"}, token, user=user_id("m-0"))["room_id"]
        state.set("big", room)
    done = state.get("big members", 1)
    while done < BIG_MEMBERS - 1:
        batch = range(done, min(done + 100, BIG_MEMBERS - 1))
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            list(pool.map(lambda n: join(token, room, user_id(f"m-{n}")), batch))
        done = batch.stop
        state.set("big members", done)
        if done % 1000 == 0:
            print(f"  big room {done}/{BIG_MEMBERS}", flush=True)
    if not state.get("big done"):
        join(tokens["scalebig"], room, None)
        rng = random.Random(1)
        for number in range(MESSAGES):
            call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/big-{number}", {"msgtype": "m.text", "body": text(rng)},
                 token, user=user_id(f"m-{rng.randrange(BIG_MEMBERS - 1)}"))
        state.set("big done", True)


def png(width, height, rng):
    """A picture that doesn't compress away: coloured 8-pixel blocks with noise."""
    def chunk(tag, data):
        body = struct.pack(">I", len(data)) + tag + data
        return body + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        base = bytes((rng.seed_row[y // 8 % 64][x // 8 % 64][c] for x in range(width) for c in range(3)))
        noise = rng.randbytes(width * 3)
        rows += bytes((b + (n & 15)) & 255 for b, n in zip(base, noise))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def media_room(token, state, tokens):
    images = state.get("images")
    if images is None:
        images = []
        for number in range(40):
            rng = random.Random(number)
            rng.seed_row = [[(rng.randrange(240), rng.randrange(240), rng.randrange(240)) for _ in range(64)] for _ in range(64)]
            width, height = rng.choice([(1600, 1200), (1200, 1600), (1080, 1080), (1920, 1080)])
            data = png(width, height, rng)
            uri = call("POST", f"/_matrix/media/v3/upload?filename=p{number}.png", token=token, raw=data, ctype="image/png", user=user_id("m-0"))["content_uri"]
            images.append({"url": uri, "w": width, "h": height, "size": len(data)})
        state.set("images", images)
        print("  images uploaded", flush=True)
    room = state.get("media")
    if room is None:
        room = call("POST", "/_matrix/client/v3/createRoom", {"preset": "public_chat", "name": "Twenty thousand events"}, token, user=user_id("m-0"))["room_id"]
        for n in range(1, 10):
            join(token, room, user_id(f"m-{n}"))
        join(tokens["scalebig"], room, None)
        state.set("media", room)
    done = state.get("media events", 0)
    now = int(time.time() * 1000)
    while done < MEDIA_EVENTS:
        for number in range(done, min(done + 500, MEDIA_EVENTS)):
            rng = random.Random(number)
            if number % 2:
                image = images[number % len(images)]
                content = {"msgtype": "m.image", "body": f"p{number}.png", "url": image["url"],
                           "info": {"mimetype": "image/png", "w": image["w"], "h": image["h"], "size": image["size"]}}
            else:
                content = {"msgtype": "m.text", "body": text(rng)}
            call("PUT", f"/_matrix/client/v3/rooms/{room}/send/m.room.message/media-{number}", content, token,
                 user=user_id(f"m-{rng.randrange(10)}"), ts=now - (MEDIA_EVENTS - number) * 60_000)
        done = min(done + 500, MEDIA_EVENTS)
        state.set("media events", done)
        if done % 2000 == 0:
            print(f"  media room {done}/{MEDIA_EVENTS}", flush=True)


# MARK: Commands

def up():
    token, state = start(), State()
    tokens = accounts(state)
    try:
        call("POST", "/_matrix/client/v3/register", {"type": "m.login.application_service", "username": "m-0", "inhibit_login": True}, token)
    except Failed as error:
        if error.errcode != "M_USER_IN_USE":
            raise
    try:
        members(token, state, BIG_MEMBERS)
        small_rooms(token, state, tokens)
        media_room(token, state, tokens)
        big_room(token, state, tokens)
    finally:
        for each in tokens.values():
            call("POST", "/_matrix/client/v3/logout", {}, each)
    status()


def status():
    state = State()
    rooms = sum(1 for i in range(ROOMS) if state.get(f"done {i}"))
    print(f"members {state.get('members', 0)}/{BIG_MEMBERS} · rooms {rooms}/{ROOMS} · big room {state.get('big members', 0) + 1 if state.get('big done') else state.get('big members', 0)}/{BIG_MEMBERS} members"
          f" · media room {state.get('media events', 0)}/{MEDIA_EVENTS} events · settings in {DIR}")


def remove():
    if "--yes" not in sys.argv:
        raise SystemExit("deletes the halo-scale server with everything in it and its settings; add --yes")
    if not os.path.exists(path("appservice.yaml")):
        private_write("appservice.yaml", "{}")
    compose("down", "-v")
    for name in ("state.json", "passwords.json", "appservice.json", "appservice.yaml"):
        if os.path.exists(path(name)):
            os.remove(path(name))


if __name__ == "__main__":
    commands = {"up": up, "status": status, "down": lambda: compose("down"), "remove": remove}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]]()
