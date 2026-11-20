#!/usr/bin/env bash
# Runs the offline-send contract test (AdapterContractTests/offlineSend) against infra/dev, stopping and starting the dev
# Synapse when the test asks (`pause-N`/`resume-N` requests; `docker stop`/`start`) (MESSAGING FR-3). The simulator can't run docker, so the test writes `<step>.req` files into
# $TEST_RUNNER_HALO_DEV_OFFLINE_DIR and this script answers each with `<step>.ack` ("ok" or the error).
#
#   scripts/contract-offline-test.sh
#
# Synapse is always started again when the script ends, also on failure or Ctrl-C, and its reachability is checked.
set -euo pipefail

container="${HALO_SYNAPSE_CONTAINER:-halo-dev-synapse-1}"
server="http://localhost:8008"
# The default docker config's osxkeychain credential helper makes the CLI hang.
DOCKER_CONFIG="$(mktemp -d -t halo-docker)"
export DOCKER_CONFIG
dir="$(mktemp -d -t halo-offline)"
watcher=""

reachable() { curl -sf -m 5 "$server/_matrix/client/versions" >/dev/null; }

cleanup() {
  [[ -n "$watcher" ]] && kill "$watcher" 2>/dev/null || true
  docker start "$container" >/dev/null 2>&1 || true
  local ok=""
  for _ in $(seq 1 30); do
    if reachable; then ok=yes; break; fi
    sleep 1
  done
  if [[ -n "$ok" ]]; then echo "contract-offline-test: $container running, $server reachable"
  else echo "contract-offline-test: $server NOT reachable after resuming $container" >&2; fi
  rm -rf "$dir" "$DOCKER_CONFIG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "contract-offline-test: container $container not found (start infra/dev first)" >&2
  exit 2
fi

answer() {  # answer <request file>
  local request="$1" name result
  name="$(basename "$request" .req)"
  case "$name" in
    pause-*)
      if result="$(docker stop -t 2 "$container" 2>&1)"; then result=ok; fi ;;
    resume-*)
      # Starting a container that is running is fine (a test's cleanup may ask twice).
      docker start "$container" >/dev/null 2>&1 || true
      result="not reachable after resume"
      for _ in $(seq 1 30); do
        if reachable; then result=ok; break; fi
        sleep 1
      done ;;
    *) result="unknown request $name" ;;
  esac
  rm -f "$request"
  echo "contract-offline-test: $name -> $result" >&2
  printf '%s\n' "$result" >"$dir/$name.tmp" && mv "$dir/$name.tmp" "$dir/$name.ack"
}

(
  set +e
  while true; do
    for request in "$dir"/*.req; do
      [[ -e "$request" ]] && answer "$request"
    done
    sleep 0.2
  done
) &
watcher=$!

status=0
TEST_RUNNER_HALO_DEV_OFFLINE_DIR="$dir" "$(dirname "$0")/contract-test.sh" offlineSend || status=$?
exit "$status"
