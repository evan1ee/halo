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

if command -v swift >/dev/null; then
  step "swift test HaloCore" swift test --package-path ios/Packages/HaloCore -Xswiftc -warnings-as-errors
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  step "swift test HaloCore (docker swift:6.2-noble)" docker run --rm -v "$PWD/ios/Packages:/w" -w /w swift:6.2-noble \
    swift test --package-path HaloCore --scratch-path /tmp/build-HaloCore -Xswiftc -warnings-as-errors
else
  skipped+=("swift tests (no swift toolchain or docker)")
fi

# Apple-only package (not Linux-buildable). Built and tested for the iOS Simulator because the
# prebuilt MatrixRustSDK has no macOS slice; adapter contract tests are skipped unless HALO_DEV_*
# is exported as TEST_RUNNER_HALO_DEV_* (docs/testing/INTEGRATION_TESTS.md).
if [[ "$(uname)" == Darwin ]] && command -v xcodebuild >/dev/null; then
  sim="${HALO_SIM:-iPhone 17}"
  step "xcodebuild test HaloApple-Package (iOS Simulator)" bash -c \
    'cd ios/Packages/HaloApple && xcodebuild -scheme HaloApple-Package -destination "platform=iOS Simulator,name=$1" test -quiet' _ "$sim"
  # The Mac's keyboard counts as a hardware keyboard, so the simulator hides the software one and the keyboard UI tests skip.
  udid="$(xcrun simctl list devices available | grep -F "    $sim (" | tail -1 | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 &&
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO ||
    skipped+=("software keyboard on $sim (the keyboard UI tests may skip)")
  if [[ -f ios/Halo.xcodeproj/project.pbxproj ]]; then
    step "xcodebuild build Halo-Debug (iOS Simulator)" xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug \
      -destination "platform=iOS Simulator,name=$sim" -quiet build
    step "xcodebuild test HaloUITests (iOS Simulator)" xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug \
      -destination "platform=iOS Simulator,name=$sim" -only-testing:HaloUITests test -quiet
  elif command -v xcodegen >/dev/null; then
    step "xcodegen + build Halo-Debug (iOS Simulator)" bash -c 'cd ios && xcodegen generate -q && xcodebuild -project Halo.xcodeproj -scheme Halo-Debug -destination "platform=iOS Simulator,name=$1" -quiet build' _ "$sim"
    step "xcodebuild test HaloUITests (iOS Simulator)" xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug \
      -destination "platform=iOS Simulator,name=$sim" -only-testing:HaloUITests test -quiet
  else skipped+=("app build and UI tests (no ios/Halo.xcodeproj; install xcodegen)"); fi
else skipped+=("HaloApple tests and app build (not macOS / no xcodebuild)"); fi

if command -v gitleaks >/dev/null; then step "gitleaks" gitleaks git --redact --no-banner .; else skipped+=("gitleaks (not installed)"); fi
if command -v swiftlint >/dev/null && [[ -f .swiftlint.yml ]]; then step "swiftlint" swiftlint --strict; else skipped+=("swiftlint (not installed or not configured yet)"); fi

for s in ${skipped[@]+"${skipped[@]}"}; do echo "SKIPPED: $s"; done
if (( failed )); then echo "prepush: FAILED"; exit 1; fi
echo "prepush: passed (see SKIPPED above for what didn't run)"
