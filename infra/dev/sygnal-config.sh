#!/usr/bin/env bash
# Renders infra/dev/secrets/sygnal.yaml from the committed template and the APNs key placed in infra/dev/secrets/
# (AuthKey_<KEYID>.p8). The team id comes from HALO_APNS_TEAM_ID. Prints no key material.
set -euo pipefail
cd "$(dirname "$0")"
: "${HALO_APNS_TEAM_ID:?set HALO_APNS_TEAM_ID to your Apple team id}"
shopt -s nullglob
keys=(secrets/AuthKey_*.p8)
(( ${#keys[@]} == 1 )) || { echo "expected exactly one secrets/AuthKey_<KEYID>.p8, found ${#keys[@]}" >&2; exit 1; }
file="$(basename "${keys[0]}")"; id="${file#AuthKey_}"; id="${id%.p8}"
sed -e "s/__KEY_FILE__/$file/" -e "s/__KEY_ID__/$id/" -e "s/__TEAM_ID__/$HALO_APNS_TEAM_ID/" sygnal/sygnal.yaml.template > secrets/sygnal.yaml
echo "wrote infra/dev/secrets/sygnal.yaml for key $id"
