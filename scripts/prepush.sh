#!/usr/bin/env bash
# Local checks before pushing (docs/development/CI_CD.md §2). Runs what this machine has and says
# plainly what it skipped — a skipped step is not a passed step (AGENTS.md §0 step 5).
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0; skipped=()
step() { echo "== $1"; shift; "$@" || failed=1; }

step "handoff (tip commit + structure, AGENTS.md §18)" python3 scripts/check_handoff.py commit HEAD
step "docs" scripts/validate-docs.sh
step "boundaries" scripts/check-boundaries.sh
step "boundaries unit tests" python3 scripts/test_check_boundaries.py
step "design tokens" scripts/check-design-tokens.sh

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

# Apple-only packages (not Linux-buildable). The adapter is built for the iOS Simulator because the
# prebuilt SDK has no macOS slice; its contract tests are skipped unless HALO_DEV_* is exported as
# TEST_RUNNER_HALO_DEV_* (docs/testing/INTEGRATION_TESTS.md).
if [[ "$(uname)" == Darwin ]] && command -v swift >/dev/null; then
  for p in HaloDesignSystem HaloPlatform HaloPersistence Features/FeatureAuth Features/FeatureRoomList Features/FeatureTimeline Features/FeatureStickers Features/FeatureSettings Features/FeatureRoomDetails Features/FeatureBotActivity; do
    step "swift test $p" swift test --package-path "ios/Packages/$p" -Xswiftc -warnings-as-errors
  done
  if command -v xcodebuild >/dev/null; then
    sim="${HALO_SIM:-iPhone 17}"
    step "xcodebuild test HaloMatrixAdapter (iOS Simulator)" bash -c \
      'cd ios/Packages/HaloMatrixAdapter && xcodebuild -scheme HaloMatrixAdapter -destination "platform=iOS Simulator,name=$1" test -quiet' _ "${HALO_SIM:-iPhone 17}"
    if [[ -f ios/Halo.xcodeproj/project.pbxproj ]]; then
      step "xcodebuild build Halo-Debug (iOS Simulator)" xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug \
        -destination "platform=iOS Simulator,name=${HALO_SIM:-iPhone 17}" -quiet build
    elif command -v xcodegen >/dev/null; then
      step "xcodegen + build Halo-Debug (iOS Simulator)" bash -c 'cd ios && xcodegen generate -q && xcodebuild -project Halo.xcodeproj -scheme Halo-Debug -destination "platform=iOS Simulator,name=$1" -quiet build' _ "${HALO_SIM:-iPhone 17}"
    else skipped+=("app build (no ios/Halo.xcodeproj; install xcodegen)"); fi
  else skipped+=("adapter tests and app build (no xcodebuild)"); fi
else skipped+=("HaloPlatform and adapter tests (not macOS)"); fi

if command -v gitleaks >/dev/null; then step "gitleaks" gitleaks git --redact --no-banner .; else skipped+=("gitleaks (not installed)"); fi
if command -v swiftlint >/dev/null && [[ -f .swiftlint.yml ]]; then step "swiftlint" swiftlint --strict; else skipped+=("swiftlint (not installed or not configured yet)"); fi

for s in "${skipped[@]}"; do echo "SKIPPED: $s"; done
if (( failed )); then echo "prepush: FAILED"; exit 1; fi
echo "prepush: passed (see SKIPPED above for what didn't run)"
