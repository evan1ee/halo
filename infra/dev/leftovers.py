#!/usr/bin/env python3
"""Rooms and devices the contract tests left on infra/dev's two shared accounts (the contract account and its peer).

    infra/dev/leftovers.py snapshot FILE   # what the accounts hold now (scripts/contract-test.sh, before a run)
    infra/dev/leftovers.py check FILE      # exit 1 and list what is there now that the snapshot didn't have
    infra/dev/leftovers.py remove          # list what the tests left behind; nothing is changed
    infra/dev/leftovers.py remove --yes    # leave and forget those rooms, sign those devices out. Can't be undone

A room counts as left behind only if its name is exactly one the tests give, no one but the two accounts is in it, and neither
contract.env nor an account's Saved Messages points to it. A device counts if it has a name the tests sign in with, or none
(plain HTTP logins); the app's own ("Halo (iPhone)") are never touched. Sticker packs of removed rooms, and of rooms the account
left earlier, also leave its pack lists. Reads ~/.config/halo-dev/contract.env (or $HALO_CONTRACT_ENV); prints no credentials.
"""
import collections, json, os, re, sys, urllib.error, urllib.parse, urllib.request

ENV_PATH = os.environ.get("HALO_CONTRACT_ENV", os.path.expanduser("~/.config/halo-dev/contract.env"))
P = "TEST_RUNNER_HALO_DEV_"
CLIENT = "/_matrix/client/v3"
ROOM_NAMES = re.compile(
    r"S\d\d(b|-S\d\d|-enc|-probe)?|Invite (accept|decline) fixture|Encrypted (evidence|poll vote evidence|reaction evidence)"
    r"|Sticker pack: Contract [0-9A-F]{5}|(New room|Room mgmt|Renamed|Legacy pack|Unavailable pack) fixture|Encrypted sticker check")
DEVICE_NAMES = re.compile(
    r"contract(-r10|-nse-app|-nse-peer|-password)?|scenario-(a1|a2|b)|policy|pushers|evidence|classic|enc(-r01)?-(me|peer)"
    r"|fixtures|offline check|leftovers|prune-sessions")


def read_env():
    values = {}
    for line in open(ENV_PATH):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            values[k] = v
    return values


class Account:
    """One signed-in account; use with `with`, which signs the login out again."""

    def __init__(self, server, user, password):
        self.server, self.user, self.password, self.token = server, user, password, None

    def __enter__(self):
        status, reply = self.call("POST", "/login", {
            "type": "m.login.password", "identifier": {"type": "m.id.user", "user": self.user}, "password": self.password,
            "initial_device_display_name": "leftovers"})
        if status != 200:
            raise SystemExit(f"{self.user}: login failed ({status})")
        self.token, self.device, self.id = reply["access_token"], reply["device_id"], reply["user_id"]
        return self

    def __exit__(self, *_):
        self.call("POST", "/logout", {})

    def call(self, method, path, body=None):
        req = urllib.request.Request(
            self.server + CLIENT + path, data=json.dumps(body).encode() if body is not None else None, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def get(self, path):
        status, reply = self.call("GET", path)
        if status != 200:
            raise SystemExit(f"{self.user}: GET {path.split('?')[0]} failed ({status})")
        return reply

    def rooms(self):
        """Every room the account is in or invited to: id -> (name, the users who are in it or invited)."""
        flt = {"room": {"timeline": {"limit": 1}, "ephemeral": {"types": []}, "account_data": {"types": []},
                        "state": {"types": ["m.room.name", "m.room.member"]}},
               "presence": {"types": []}, "account_data": {"types": []}}
        reply = self.get("/sync?timeout=0&full_state=true&filter=" + urllib.parse.quote(json.dumps(flt)))
        found = {}
        for kind, key in (("join", "state"), ("invite", "invite_state")):
            for room, data in reply.get("rooms", {}).get(kind, {}).items():
                name, members = None, set()
                for e in data.get(key, {}).get("events", []) + data.get("timeline", {}).get("events", []):
                    if e["type"] == "m.room.name" and e.get("state_key") == "":
                        name = e["content"].get("name")
                    elif e["type"] == "m.room.member":
                        (members.add if e["content"].get("membership") in ("join", "invite") else members.discard)(e["state_key"])
                found[room] = (name, members)
        return found

    def devices(self):
        """Every device but this login and the app's own: id -> name."""
        return {d["device_id"]: d.get("display_name") for d in self.get("/devices")["devices"]
                if d["device_id"] != self.device and d.get("display_name") != "Halo (iPhone)"}

    def account_data(self, kind):
        status, reply = self.call("GET", f"/user/{urllib.parse.quote(self.id)}/account_data/{kind}")
        if status not in (200, 404):
            raise SystemExit(f"{self.user}: reading {kind} failed ({status})")
        return reply if status == 200 else {}

    def put_account_data(self, kind, content):
        status, _ = self.call("PUT", f"/user/{urllib.parse.quote(self.id)}/account_data/{kind}", content)
        if status != 200:
            raise SystemExit(f"{self.user}: writing {kind} failed ({status})")

    def leave(self, room):
        path = "/rooms/" + urllib.parse.quote(room, safe="")
        status, reply = self.call("POST", path + "/leave", {})
        if status == 200:
            status, reply = self.call("POST", path + "/forget", {})
        if status != 200:
            print(f"  {room}: {status} {reply.get('error', '')}")
        return status == 200

    def sign_out(self, devices):
        body = {"devices": devices}
        status, reply = self.call("POST", "/delete_devices", body)
        if status == 401:  # user-interactive authentication: confirm with the password
            body["auth"] = {"type": "m.login.password", "session": reply["session"],
                            "identifier": {"type": "m.id.user", "user": self.user}, "password": self.password}
            status, reply = self.call("POST", "/delete_devices", body)
        if status != 200:
            print(f"  signing out failed: {status}")
        return status == 200


def accounts(values):
    for kind in ("", "PEER_"):
        if values.get(P + kind + "USER"):
            yield Account(values[P + "SERVER"], values[P + kind + "USER"], values[P + kind + "PASSWORD"])


def state(account):
    return {"rooms": {room: name for room, (name, _) in account.rooms().items()}, "devices": account.devices()}


def snapshot(values):
    now = {}
    for account in accounts(values):
        with account:
            now[account.user] = state(account)
    return now


def check(values, before):
    left = 0
    for user, now in snapshot(values).items():
        for kind, things in now.items():
            for thing, name in things.items():
                if thing not in before.get(user, {}).get(kind, {}):
                    left += 1
                    print(f"left behind on {user}: {kind[:-1]} {name or '(no name)'} {thing}")
    return 1 if left else 0


def count(names):
    kinds = collections.Counter(re.sub(r" [0-9A-F]{5}$", " *", n) if n else "(no name)" for n in names)
    return ", ".join(f"{n} ×{c}" for n, c in sorted(kinds.items(), key=lambda k: (-k[1], k[0]))) or "none"


def remove(values, yes):
    ours = {f"@{a.user}:" for a in accounts(values)}
    kept = {v for k, v in values.items() if k.endswith("_ROOM")}
    failed = 0
    for account in accounts(values):
        with account:
            keep = kept | {account.account_data("one.mbm.halo.saved_room").get("room_id")}
            rooms = account.rooms()
            doomed = {room: name for room, (name, members) in rooms.items()
                      if room not in keep and name and ROOM_NAMES.fullmatch(name)
                      and all(any(m.startswith(o) for o in ours) for m in members)}
            devices = {d: n for d, n in account.devices().items() if n is None or DEVICE_NAMES.fullmatch(n)}
            stays = set(rooms) - set(doomed)
            print(f"{account.user}: {len(doomed)} of {len(rooms)} rooms, {len(devices)} devices")
            print(f"  rooms: {count(doomed.values())}")
            print(f"  rooms kept: {count(rooms[r][0] for r in stays)}")
            print(f"  devices: {count(devices.values())}")
            # Pack lists first: a pack must not be listed once its room is gone (the panel would report it unavailable).
            for kind in ("m.image_pack.rooms", "one.mbm.halo.sticker_rooms"):
                content = account.account_data(kind)
                listed = content.get("rooms") or {}
                gone = [r for r in listed if r not in stays]
                if gone:
                    print(f"  {kind}: {len(gone)} of {len(listed)} entries (room removed or left)")
                    if yes:
                        content["rooms"] = {r: v for r, v in listed.items() if r in stays} if isinstance(listed, dict) else [r for r in listed if r in stays]
                        account.put_account_data(kind, content)
            if yes:
                failed += sum(not account.leave(room) for room in doomed)
                failed += 0 if not devices or account.sign_out(sorted(devices)) else 1
    print(("removed" if not failed else f"{failed} failed") if yes else "nothing changed; --yes removes them")
    return 1 if failed else 0


def main():
    args = sys.argv[1:]
    if args[:1] == ["remove"] and args[1:] in ([], ["--yes"]):
        return remove(read_env(), "--yes" in args)
    if len(args) == 2 and args[0] == "snapshot":
        with open(args[1], "w") as f:
            json.dump(snapshot(read_env()), f)
        return 0
    if len(args) == 2 and args[0] == "check":
        with open(args[1]) as f:
            return check(read_env(), json.load(f))
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
