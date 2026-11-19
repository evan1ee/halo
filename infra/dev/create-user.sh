#!/usr/bin/env bash
# Create a user on the local dev homeserver with the registration shared secret.
# Usage: infra/dev/create-user.sh <localpart> [--admin]
# The password comes from HALO_DEV_PASSWORD or a prompt, and reaches Synapse through stdin
# (--password-file /dev/stdin), so it never appears in a process list.
set -euo pipefail
cd "$(dirname "$0")"
localpart="${1:?usage: create-user.sh <localpart> [--admin]}"
admin_flag="--no-admin"
[[ "${2:-}" == "--admin" ]] && admin_flag="--admin"
if [[ -z "${HALO_DEV_PASSWORD:-}" ]]; then
  read -r -s -p "Password for ${localpart}: " HALO_DEV_PASSWORD; echo
fi
printf '%s' "$HALO_DEV_PASSWORD" | docker compose exec -T synapse \
  register_new_matrix_user -c /data/homeserver.yaml -u "$localpart" --password-file /dev/stdin \
  "$admin_flag" --exists-ok http://localhost:8008
