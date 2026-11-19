#!/usr/bin/env bash
# Local checks before pushing (docs/development/CI_CD.md §2). Runs what this machine has and says
# plainly what it skipped — a skipped step is not a passed step (AGENTS.md §0 step 5).
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0; skipped=()
step() { echo "== $1"; shift; "$@" || failed=1; }

step "docs" scripts/validate-docs.sh
step "boundaries" scripts/check-boundaries.sh

packages=(HaloFoundation HaloDomain HaloTestSupport HaloApplication)
if command -v swift >/dev/null; then
  for p in "${packages[@]}"; do step "swift test $p" swift test --package-path "ios/Packages/$p" -Xswiftc -warnings-as-errors; done
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  for p in "${packages[@]}"; do
    step "swift test $p (docker swift:6.2-noble)" docker run --rm -v "$PWD/ios/Packages:/w" -w /w swift:6.2-noble \
      swift test --package-path "$p" --scratch-path "/tmp/build-$p" -Xswiftc -warnings-as-errors
  done
else
  skipped+=("swift tests (no swift toolchain or docker)")
fi

if command -v gitleaks >/dev/null; then step "gitleaks" gitleaks git --redact --no-banner .; else skipped+=("gitleaks (not installed)"); fi
if command -v swiftlint >/dev/null && [[ -f .swiftlint.yml ]]; then step "swiftlint" swiftlint --strict; else skipped+=("swiftlint (not installed or not configured yet)"); fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
if (( failed )); then echo "prepush: FAILED"; exit 1; fi
echo "prepush: passed (see SKIPPED above for what didn't run)"
