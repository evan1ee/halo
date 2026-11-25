#!/usr/bin/env bash
# The throwaway test server (infra/test): starts it, runs something against it, removes it.
#
#   infra/test/run.sh scenarios [S04 F02 …]   # the scenario driver, with the fault cases (Linux CI and local)
#   infra/test/run.sh faults [test …]         # the adapter's fault tests in a simulator (Mac)
#   infra/test/run.sh interop [test …]        # the wire-level interoperability matrix in a simulator (Mac)
#   infra/test/run.sh search [test …]         # message search against a real server (S-SRCH, Mac)
#   HALO_TEST_KEEP=1 …                        # leave it running; `infra/test/run.sh down` removes it
set -euo pipefail
cd "$(dirname "$0")/../.."
compose=(docker compose -f infra/test/docker-compose.yml)
export HALO_TEST_SERVER="http://localhost:${HALO_TEST_PORT:-8208}"
export HALO_TEST_PROXY="http://localhost:${HALO_TEST_PROXY_PORT:-8218}"
export HALO_TEST_CONTROL="http://localhost:${HALO_TEST_CONTROL_PORT:-8219}"
command="${1:-}"; shift || true

case "$command" in
  down) exec "${compose[@]}" down -v ;;
  scenarios|faults|interop|search) ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac

cleanup() { [[ "${HALO_TEST_KEEP:-}" == 1 ]] || "${compose[@]}" down -v >/dev/null 2>&1; }
trap cleanup EXIT
"${compose[@]}" up -d --wait --quiet-pull >/dev/null 2>&1 || { "${compose[@]}" logs --tail 40; exit 1; }
curl -fsS -X DELETE "$HALO_TEST_CONTROL/rules" >/dev/null

if [[ "$command" == scenarios ]]; then
  # Devices talk through the proxy (the fault cases break it); accounts are made in the container.
  HALO_DEV_SERVER="$HALO_TEST_PROXY" HALO_DEV_SYNAPSE_CONTAINER=halo-test-synapse-1 python3 tools/scenario-driver/run_scenarios.py "$@"
  exit
fi

password="$(openssl rand -hex 12)"
user="fault$(openssl rand -hex 3)"
for name in "$user" "${user}peer"; do
  printf %s "$password" | docker exec -i halo-test-synapse-1 register_new_matrix_user -c /data/homeserver.yaml -u "$name" --password-file /dev/stdin --no-admin http://localhost:8008 >/dev/null
done
export TEST_RUNNER_HALO_FAULT_SERVER="$HALO_TEST_PROXY" TEST_RUNNER_HALO_FAULT_DIRECT="$HALO_TEST_SERVER" TEST_RUNNER_HALO_FAULT_CONTROL="$HALO_TEST_CONTROL"
export TEST_RUNNER_HALO_FAULT_USER="$user" TEST_RUNNER_HALO_FAULT_PASSWORD="$password"
suite=FaultTests; [[ "$command" == interop ]] && suite=InteropTests; [[ "$command" == search ]] && suite=SearchContractTests
only=("-only-testing:HaloMatrixAdapterTests/$suite")
if (( $# )); then only=(); for name in "$@"; do only+=("-only-testing:HaloMatrixAdapterTests/$suite/${name%()}()"); done; fi
log="$(mktemp -t halo-faults)"
status=0
(cd ios/Packages/HaloApple && xcodebuild -scheme HaloApple-Package -destination "platform=iOS Simulator,name=${HALO_SIM:-iPhone 17}" test "${only[@]}") >"$log" 2>&1 || status=$?
grep -E '^(✔|✘) (Test|Suite)|Test run with|^FAULT |^SEARCH ' "$log" || true
[[ $status -eq 0 ]] || echo "faults: failed (exit $status); full log: $log" >&2
exit "$status"
