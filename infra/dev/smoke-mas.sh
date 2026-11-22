#!/usr/bin/env bash
# Smoke-checks the isolated infra/dev MAS + Synapse stack (V-AUTH-1).
set -euo pipefail

SYNAPSE_URL="${HALO_DEV_MAS_SYNAPSE_URL:-http://127.0.0.1:8009}"
MAS_URL="${HALO_DEV_MAS_URL:-http://127.0.0.1:8080}"

echo "Checking MAS OIDC discovery at ${MAS_URL}/.well-known/openid-configuration ..."
curl -fsS "${MAS_URL}/.well-known/openid-configuration" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for key in ("issuer", "authorization_endpoint", "token_endpoint"):
    assert doc.get(key), f"missing {key}"
print("  issuer:", doc["issuer"])
print("  authorization_endpoint:", doc["authorization_endpoint"])
'

echo "Checking Synapse auth_metadata at ${SYNAPSE_URL}/_matrix/client/v1/auth_metadata ..."
curl -fsS "${SYNAPSE_URL}/_matrix/client/v1/auth_metadata" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc.get("issuer"), "missing issuer"
assert doc.get("authorization_endpoint"), "missing authorization_endpoint"
print("  Synapse delegated issuer:", doc["issuer"])
'

echo "smoke-mas: ok"
