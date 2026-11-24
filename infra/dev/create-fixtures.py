#!/usr/bin/env python3
"""Create the throwaway accounts and rooms the adapter contract tests need on infra/dev, and write
~/.config/halo-dev/contract.env (override with $HALO_CONTRACT_ENV). Idempotent: values already in the file are kept and the
fixtures they point to are not created again. Passwords are generated, written only to that file (mode 600) and never printed.

    infra/dev/create-fixtures.py [--new-e2ee]

Needs infra/dev running (docker compose -f infra/dev/docker-compose.yml up -d) and Docker access (docker exec into the Synapse container).
Fixtures: the contract account; a timeline room (first, second, a notice, waves, a redacted message, blue.png 64x48); a second
throwaway account for the Encryption contract. The sticker room (m.room.image_pack "cats") is created too.
"""
import json, os, secrets, struct, subprocess, sys, tempfile, time, urllib.parse, urllib.request, urllib.error, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.environ.get("HALO_CONTRACT_ENV", os.path.expanduser("~/.config/halo-dev/contract.env"))
P = "TEST_RUNNER_HALO_DEV_"
SERVER = "http://localhost:8008"


def read_env():
    values = {}
    if os.path.exists(ENV_PATH):
        for line in open(ENV_PATH):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                values[k] = v
    return values


def write_env(values):
    os.makedirs(os.path.dirname(ENV_PATH), exist_ok=True)
    body = "# Halo contract-test settings for infra/dev (throwaway local accounts). Never commit this file.\n"
    body += "".join(f"{k}={v}\n" for k, v in values.items())
    fd = os.open(ENV_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(body)
    os.chmod(ENV_PATH, 0o600)


def call(method, path, body=None, token=None, raw=None, ctype="application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(SERVER + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", ctype)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path.split('?')[0]} failed: {e.code} {e.read()[:200]!r}")


def ensure_user(name, password):
    # docker exec, not compose: a throwaway DOCKER_CONFIG (the default credential helper can hang) has no compose plugin
    env = dict(os.environ, DOCKER_CONFIG=tempfile.mkdtemp(prefix="halo-docker-"))
    container = os.environ.get("HALO_DEV_SYNAPSE_CONTAINER", "halo-dev-synapse-1")
    subprocess.run(
        ["docker", "exec", "-i", container, "register_new_matrix_user", "-c", "/data/homeserver.yaml", "-u", name,
         "--password-file", "/dev/stdin", "--no-admin", "--exists-ok", "http://localhost:8008"],
        input=password.encode(), env=env, check=True, stdout=subprocess.DEVNULL, timeout=120)


_SESSIONS = []  # tokens of the logins below; signed out at the end so each run leaves no device behind


def login(name, password):
    r = call("POST", "/_matrix/client/v3/login", {
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": name},
        "password": password, "initial_device_display_name": "fixtures"})
    _SESSIONS.append(r["access_token"])
    return r["access_token"]


def png(width, height, rgb):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


def upload(token, data, filename):
    r = call("POST", f"/_matrix/media/v3/upload?filename={filename}", token=token, raw=data, ctype="image/png")
    return r["content_uri"]


def send(token, room, content, etype="m.room.message"):
    return call("PUT", f"/_matrix/client/v3/rooms/{room}/send/{etype}/{secrets.token_hex(8)}", content, token)["event_id"]


def create_room(token, name):
    return call("POST", "/_matrix/client/v3/createRoom", {"name": name, "preset": "private_chat"}, token)["room_id"]


def main():
    values = read_env()
    user = values.get(P + "USER") or "contracttester"
    password = values.get(P + "PASSWORD") or secrets.token_urlsafe(18)
    ensure_user(user, password)
    values.update({P + "SERVER": SERVER, P + "USER": user, P + "PASSWORD": password})
    token = login(user, password)

    if not values.get(P + "TIMELINE_ROOM"):
        room = create_room(token, "Timeline fixture")
        for body in ("first", "second"):
            send(token, room, {"msgtype": "m.text", "body": body})
        send(token, room, {"msgtype": "m.notice", "body": "a notice"})
        send(token, room, {"msgtype": "m.text", "body": "waves"})
        doomed = send(token, room, {"msgtype": "m.text", "body": "to be redacted"})
        call("PUT", f"/_matrix/client/v3/rooms/{room}/redact/{doomed}/{secrets.token_hex(8)}", {"reason": "fixture"}, token)
        data = png(64, 48, (0, 0, 255))
        uri = upload(token, data, "blue.png")
        send(token, room, {"msgtype": "m.image", "body": "blue.png", "url": uri,
                           "info": {"mimetype": "image/png", "w": 64, "h": 48, "size": len(data)}})
        values[P + "TIMELINE_ROOM"] = room

    if not values.get(P + "STICKER_ROOM"):
        room = create_room(token, "Sticker fixture")
        data = png(8, 8, (255, 200, 0))
        images = {n: {"url": upload(token, data, n + ".png"), "body": label,
                      "info": {"mimetype": "image/png", "w": 8, "h": 8, "size": len(data)}, "usage": ["sticker"]}
                  for n, label in (("wave", "Waving"), ("dance", "Dancing"))}
        call("PUT", f"/_matrix/client/v3/rooms/{room}/state/m.room.image_pack/cats",
             {"pack": {"display_name": "Cats"}, "images": images}, token)
        me = call("GET", "/_matrix/client/v3/account/whoami", token=token)["user_id"]
        packs = {}
        try:
            packs = call("GET", f"/_matrix/client/v3/user/{me}/account_data/m.image_pack.rooms", token=token)
        except SystemExit:
            pass  # not set yet
        packs.setdefault("rooms", {}).setdefault(room, {})["cats"] = {}
        call("PUT", f"/_matrix/client/v3/user/{me}/account_data/m.image_pack.rooms", packs, token)
        values[P + "STICKER_ROOM"] = room

    # A second account that shares a room with the contract account, for tests that need messages from someone else.
    if not values.get(P + "PEER_USER") or not values.get(P + "UNREAD_ROOM"):
        peer, peer_pw = values.get(P + "PEER_USER") or "contractpeer", values.get(P + "PEER_PASSWORD") or secrets.token_urlsafe(18)
        ensure_user(peer, peer_pw)
        peer_token = login(peer, peer_pw)
        me = call("GET", "/_matrix/client/v3/account/whoami", token=token)["user_id"]
        room = call("POST", "/_matrix/client/v3/createRoom", {"name": "Unread fixture", "preset": "private_chat", "invite": [me]}, peer_token)["room_id"]
        call("POST", f"/_matrix/client/v3/join/{urllib.parse.quote(room)}", {}, token)
        values.update({P + "PEER_USER": peer, P + "PEER_PASSWORD": peer_pw, P + "UNREAD_ROOM": room})

    # The Encryption contract sets recovery up, which an account can do once: --new-e2ee makes it a fresh account.
    if not values.get(P + "E2EE_USER") or "--new-e2ee" in sys.argv:
        e2ee_user, e2ee_pw = "e2ee" + secrets.token_hex(4), secrets.token_urlsafe(18)
        ensure_user(e2ee_user, e2ee_pw)
        values[P + "E2EE_USER"], values[P + "E2EE_PASSWORD"] = e2ee_user, e2ee_pw

    values.pop(P + "ROOMS", None)  # written by older versions; the tests ask the server
    write_env(values)
    for session in _SESSIONS:
        try:
            call("POST", "/_matrix/client/v3/logout", {}, session)
        except SystemExit:
            pass  # already gone
    print(f"wrote {ENV_PATH}: {len(values)} settings (values not shown)")


if __name__ == "__main__":
    sys.exit(main())
