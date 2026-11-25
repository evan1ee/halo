# Build and Release

## 1. Builds
| Configuration | Signing | Distribution |
|---|---|---|
| Debug | Automatic (development) | Simulator / own devices |
| Beta | Distribution (App Store Connect) | TestFlight internal → external |
| Release | Distribution | App Store (only after G-SHIP, ROADMAP §7) |

Archive from Xcode or `xcodebuild archive` on the founder's Mac; upload with Xcode Organizer or `xcrun altool`/Transporter (Xcode Cloud is a possible later option, not decided).

## 2. Code signing
- Team-managed automatic signing for development; distribution certificate and provisioning profiles created in the developer portal, stored in the login keychain and the password manager — never in the repo.
- Entitlements files are committed (they contain no secrets).
- APNs: a token-based auth key (`.p8`) for Sygnal, stored on the server only.

## 3. SDK bump procedure
1. Branch `chore/sdk-<version>`.
2. Update the package to the new exact version + checksum; record the upstream commit in `ios/SDKVERSION.md` (V-SDK-1).
3. Regenerate the licence inventory for that commit with the sentry feature; diff; review new licences (gate).
4. Read the upstream changelog/CHANGELOG entries for `matrix-sdk-ffi`, `matrix-sdk-ui`, `matrix-sdk-crypto`; note breaking changes and security fixes.
5. Fix compile errors **only inside `HaloMatrixAdapter`**.
6. Run: unit tests, adapter contract tests, FFI smoke, scenario suite (local FFI run), NSE memory measurement.
7. Update [../SOURCES.md](../SOURCES.md) pinned refs and any [VERIFIED] facts that changed.
8. Merge; ship in the next Beta.

## 4. Release process (Beta)
1. All CI green on `main`; local suites green (adapter, FFI, UI smoke, scenarios).
2. Version bump (`MARKETING_VERSION` = `YYYY.MINOR.PATCH`; build number = CI run number or date stamp).
3. Licence notices regenerated; Acknowledgements screen checked.
4. Export compliance answered (V-LEGAL in LICENSE_COMPLIANCE §5).
5. Device checklist ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md) §8).
6. Archive → upload → release notes (features, SDK version, known issues).
7. Auditor reports from the previous Beta reviewed (AC-U8).
8. Privacy report of the archive checked: privacy manifests of the app and all three extensions present and true (AC-UX-12).
9. For an external TestFlight build: the "Ship-ready definition" in [../ROADMAP.md](../ROADMAP.md) is met and the release plan
   stage (Beta 1 → Beta 2 → 1.0) is named in the release notes.

## 5. Crash reporting and observability
TestFlight/App Store crash reports + MetricKit + the diagnostics export ([../architecture/LOGGING_AND_DIAGNOSTICS.md](../architecture/LOGGING_AND_DIAGNOSTICS.md)). No third-party crash SDK (D114). MetricKit isn't wired yet (ROADMAP M17-2).

## 5b. 1.0 release
1. Feature freeze at the Beta 2 cut: only P0/P1 fixes; unfinished C tasks move to 1.x (ROADMAP §1).
2. Release candidate: everything in §4, plus the upgrade path from each Beta build, two G-PERF runs, the full device checklist on the oldest supported device and an iPad, and the interop matrix.
3. Submit with review notes (D113 Sentry note, review server and account per Q-REVIEW, how to report content), phased release on.
4. Watch daily for 14 days: crash-free sessions, hangs, push delivery and gateway health, support mail. **Stop rule:** pause the rollout on any P0, or crash-free sessions under 99.5 %.
5. A hotfix branch from the release tag is rehearsed before submission.

## 6. Rollback
Expire the bad TestFlight build. Re-promote the previous build **only if it ships the same SDK version** — SDK stores can't be downgraded ([../data/MIGRATIONS.md](../data/MIGRATIONS.md) §3). Otherwise ship a fix-forward build: the previous app code with the current (or newer) SDK, under a new build number. Database migrations are forward-only; a rollback build must accept the newer schema (read-only degrade) or rebuild `halo.sqlite` (derived data) — never drop intents silently.
