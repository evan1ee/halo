#!/usr/bin/env bash
# Runs HaloMatrixAdapter contract tests against infra/dev (docs/development/AUTONOMOUS_LOOP.md §6).
#
#   scripts/contract-test.sh                  # the whole AdapterContractTests suite
#   scripts/contract-test.sh stickers createPack
#   scripts/contract-test.sh ClassicSyncEvidenceTests/encryptedNonMessageEvidence
#
# Settings come from $HALO_CONTRACT_ENV (default ~/.config/halo-dev/contract.env), a private file outside the repository
# with TEST_RUNNER_HALO_DEV_* lines. Values are never printed. Tests whose fixture variable is missing skip themselves.
set -euo pipefail

env_file="${HALO_CONTRACT_ENV:-$HOME/.config/halo-dev/contract.env}"
if [[ ! -f "$env_file" ]]; then
  echo "contract-test: $env_file not found (see docs/development/AUTONOMOUS_LOOP.md §6)" >&2
  exit 2
fi

# A full run, or the encryption test, needs a fresh E2EE account (recovery can be set up once) and a current room count.
if [[ $# -eq 0 || " $* " == *" encryption "* || " $* " == *" roomList "* ]]; then
  "$(dirname "$0")/../infra/dev/create-fixtures.py" --new-e2ee >/dev/null
fi
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

if ! curl -sf -m 5 "${TEST_RUNNER_HALO_DEV_SERVER:-http://localhost:8008}/_matrix/client/versions" >/dev/null; then
  echo "contract-test: infra/dev is not reachable; start it with 'docker compose -f infra/dev/docker-compose.yml up -d'" >&2
  exit 2
fi

only=()
if [[ $# -eq 0 ]]; then
  only=(-only-testing:HaloMatrixAdapterTests/AdapterContractTests -only-testing:HaloMatrixAdapterTests/ClassicSyncEvidenceTests -only-testing:HaloMatrixAdapterTests/ServerReadStateScenarioTests)
else
  # A bare name is an AdapterContractTests test; `Suite/test` names a test of another suite (e.g. ClassicSyncEvidenceTests).
  for name in "$@"; do
    if [[ "$name" == */* ]]; then only+=("-only-testing:HaloMatrixAdapterTests/${name%()}()")
    else only+=("-only-testing:HaloMatrixAdapterTests/AdapterContractTests/${name%()}()"); fi
  done
fi

cd "$(dirname "$0")/../ios/Packages/HaloMatrixAdapter"
log="$(mktemp -t halo-contract)"
status=0
xcodebuild -scheme HaloMatrixAdapter -destination "platform=iOS Simulator,name=${HALO_SIM:-iPhone 17}" test "${only[@]}" >"$log" 2>&1 || status=$?
grep -E '^(✔|✘) (Test|Suite)|Test run with' "$log" || true
[[ $status -eq 0 ]] || echo "contract-test: failed (exit $status); full log: $log" >&2
exit "$status"
