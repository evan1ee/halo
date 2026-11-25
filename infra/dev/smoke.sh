#!/usr/bin/env bash
# Smoke test for infra/dev: the homeserver advertises native sliding sync, a user can log in with
# a password (D64), and the Simplified Sliding Sync endpoint (F-SPEC-5) answers for that user.
# Creates a fresh user `smoke-<random>` with a random password on each run. Prints no secrets.
set -euo pipefail
cd "$(dirname "$0")"
base="http://${HALO_DEV_HOST:-127.0.0.1}:${HALO_DEV_PORT:-8008}"
pw_file="$(mktemp)"; trap 'rm -f "$pw_file"' EXIT
head -c 24 /dev/urandom | base64 | tr -d '\n/+=' > "$pw_file"
user="smoke-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

echo "1. versions advertise native sliding sync"
curl -fsS "$base/_matrix/client/versions" | python3 -c '
import json,sys; v=json.load(sys.stdin); f=v.get("unstable_features",{})
assert f.get("org.matrix.simplified_msc3575") is True, "native sliding sync not advertised"
print("   ok:", ", ".join(v["versions"][-3:]))'

echo "2. create user and log in with a password"
HALO_DEV_PASSWORD="$(cat "$pw_file")" ./create-user.sh "$user" >/dev/null
token="$(python3 - "$base" "$pw_file" "$user" <<'PY'
import json, sys, urllib.request
base, pw_file, user = sys.argv[1], sys.argv[2], sys.argv[3]
body = {"type": "m.login.password", "identifier": {"type": "m.id.user", "user": user},
        "password": open(pw_file).read(), "initial_device_display_name": "halo-smoke"}
req = urllib.request.Request(base + "/_matrix/client/v3/login", json.dumps(body).encode(),
                             {"Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req))["access_token"])
PY
)"
echo "   ok: access token received"

echo "3. simplified sliding sync responds"
curl -fsS -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  -d '{"lists":{"all":{"ranges":[[0,10]],"timeline_limit":1,"required_state":[]}}}' \
  "$base/_matrix/client/unstable/org.matrix.simplified_msc3575/sync" | python3 -c '
import json,sys; r=json.load(sys.stdin); assert "pos" in r, r; print("   ok: pos", r["pos"], "rooms", len(r.get("rooms",{})))'

python3 - "$base" "$pw_file" "$user" 3<<<"$token" <<'PY'
import json, os, sys, urllib.error, urllib.request
base, pw_file, user = sys.argv[1], sys.argv[2], sys.argv[3]
token = os.fdopen(3).read().strip()
def deactivate(body):
    req = urllib.request.Request(base + "/_matrix/client/v3/account/deactivate", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + token})
    return urllib.request.urlopen(req)
try:
    deactivate({"erase": True})
except urllib.error.HTTPError as e:  # user-interactive authentication: confirm with the password
    if e.code != 401: raise
    deactivate({"erase": True, "auth": {"type": "m.login.password", "session": json.load(e)["session"],
                "identifier": {"type": "m.id.user", "user": user}, "password": open(pw_file).read()}})
print("4. the throwaway user is deactivated")
PY
echo "smoke: all checks passed"
