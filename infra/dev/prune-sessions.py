#!/usr/bin/env python3
"""Sign out the contract account's leftover devices on infra/dev (every run of the contract tests or create-fixtures.py that
died before its logout leaves one), keeping devices whose name is in KEEP (default "Halo (iPhone)", the app's own session).
Reads ~/.config/halo-dev/contract.env (override with $HALO_CONTRACT_ENV); never prints credentials.

    infra/dev/prune-sessions.py [--keep "Halo (iPhone)"] [--dry-run]
"""
import json, os, sys, urllib.request, urllib.error

ENV_PATH = os.environ.get("HALO_CONTRACT_ENV", os.path.expanduser("~/.config/halo-dev/contract.env"))
P = "TEST_RUNNER_HALO_DEV_"


def env():
    values = {}
    for line in open(ENV_PATH):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            values[k] = v
    return values


def call(server, method, path, body=None, token=None):
    req = urllib.request.Request(server + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main():
    args = sys.argv[1:]
    keep = {args[args.index("--keep") + 1]} if "--keep" in args else {"Halo (iPhone)"}
    values = env()
    server, user, password = values[P + "SERVER"], values[P + "USER"], values[P + "PASSWORD"]
    status, login = call(server, "POST", "/_matrix/client/v3/login", {
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": user}, "password": password,
        "initial_device_display_name": "prune-sessions"})
    if status != 200:
        raise SystemExit(f"login failed: {status}")
    token, mine = login["access_token"], login["device_id"]
    try:
        _, listing = call(server, "GET", "/_matrix/client/v3/devices", token=token)
        doomed = [d["device_id"] for d in listing["devices"] if d["device_id"] != mine and d.get("display_name") not in keep]
        print(f"{len(listing['devices']) - 1} other sessions, {len(doomed)} to sign out")
        if "--dry-run" in args or not doomed:
            return
        status, challenge = call(server, "POST", "/_matrix/client/v3/delete_devices", {"devices": doomed}, token)
        if status == 401:  # user-interactive authentication: confirm with the password
            auth = {"type": "m.login.password", "session": challenge["session"],
                    "identifier": {"type": "m.id.user", "user": user}, "password": password}
            status, challenge = call(server, "POST", "/_matrix/client/v3/delete_devices", {"devices": doomed, "auth": auth}, token)
        print("signed out" if status == 200 else f"failed: {status}")
    finally:
        call(server, "POST", "/_matrix/client/v3/logout", {}, token)


if __name__ == "__main__":
    sys.exit(main())
