# Build and Release

## 1. Builds
| Configuration | Signing | Distribution |
|---|---|---|
| Debug | Automatic (development) | Simulator / own devices |
| Beta | Distribution (App Store Connect) | TestFlight internal → external |
| Release | Distribution | App Store (only after M10 + legal review) |

Archive from Xcode or `xcodebuild archive` on the founder's Mac; upload with Xcode Organizer or `xcrun altool`/Transporter **[DECISION: Xcode Cloud optional later]**.

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

## 5. Crash reporting and observability
TestFlight/App Store crash reports + MetricKit + the diagnostics export ([../architecture/LOGGING_AND_DIAGNOSTICS.md](../architecture/LOGGING_AND_DIAGNOSTICS.md)). No third-party crash SDK (Q-CRASH before public release).

## 6. Rollback
Expire the bad TestFlight build and re-promote the previous one. Database migrations are forward-only; a rollback build must accept the newer schema (read-only degrade) or rebuild `halo.sqlite` (derived data) — never drop intents silently.
