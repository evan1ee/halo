# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `feat/m15-ship-readiness` · PRs #1–#56 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** **ALL autonomous engineering work across M0–M15, ADR-0022 steps 1–4 (D86), and Tech Debt Phases A–D is complete!** Only founder (`👤`) and physical-device (`📱`) items remain (listed in §5).
- **Milestones:** M0–M15 done except founder/device items (G-FFI/G-UNREAD/G-NSE confirmations, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, physical-device NFR-1/NFR-2/MetricKit run, Q-BRAND sign-in illustration, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE, legal/export/privacy nutrition labels). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (`HaloCore` 165 tests, `HaloApple-Package` all 16 targets incl. `BotActionStoreTests` and `privacyManifestsAreValid`, `Halo-Debug` app build, `HaloUITests` with `performAccessibilityAudit()`, `validate-docs.sh`, `check-boundaries.sh`, `test_check_boundaries.py`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks`).
- **CI:** PRs #1–#56 merged. Linux CI runs `HaloCore` tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **M15 Ship readiness + Tech Debt Phase D (`feat/m15-ship-readiness`, SR-01/SR-05, TD-04/TD-08):**
  - `PrivacyInfo.xcprivacy` for app (`ios/App/Resources/`) and NSE (`ios/NotificationService/`): `NSPrivacyTracking = false`, no collected data, required-reason APIs (`UserDefaults`, `FileTimestamp`, `DiskSpace`), validated in `AcknowledgementsTests.privacyManifestsAreValid`.
  - In-app feedback (`FeedbackSheetView`, Settings → `"Send feedback"`) with opt-in diagnostics `.zip` attachment (never automatic; PRIVACY §1); `"What's New"` sheet (`WhatsNewView`) shown once per marketing version via `PreferencesPort.lastSeenWhatsNewVersion`; About section links (`Privacy policy`, `Support`, `What's New`).
  - Cold-launch performance metric test `testLaunchPerformanceMetric()` (`XCTApplicationLaunchMetric`) in `HaloUITests` (opt-in via `HALO_RUN_PERF_TESTS=1`).
  - Tech Debt Phase D: `v9-bot-action` append-only GRDB migration + `BotActionStore` + `BotActionStoreTests` (TD-08); manual-dispatch `.github/workflows/macos-build.yml` (TD-04).
- **M14 Accessibility & localisation + `HaloUITests` (`PR #56`, merged `d188a4d`, TD-03):** VoiceOver pass (`RoomRow.accessibilitySummary` + unit tests, `.accessibilityActions` on room & timeline rows, `BotCardView` 44×44 hit targets & state values), AX5 `SignInView` fix, `HaloUITests` with `performAccessibilityAudit()`, `Localizable.xcstrings` String Catalog.
- **ADR-0022 step 4 — two-manifest consolidation (`PR #55`, merged `433e337`, D86):** replaced 20 `Package.swift` manifests with `HaloCore` (Linux) and `HaloApple` (16 iOS/Apple targets), organized `HaloMatrixAdapter` and `HaloTestSupport` into 12 matching area folders; `.build` disk footprint dropped from **6.5 GB** to **530 MB** (92% reduction).

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 (all 4 steps complete).

## 4. Modified files (this push)
- **Privacy & CI:** `ios/App/Resources/PrivacyInfo.xcprivacy`, `ios/NotificationService/PrivacyInfo.xcprivacy`, `.github/workflows/macos-build.yml`.
- **Persistence (TD-08):** `HaloPersistence/HaloDatabase.swift` (`v9-bot-action`), `HaloPersistence/BotActionStore.swift`, `HaloPersistenceTests/BotActionStoreTests.swift`.
- **Settings, Preferences & App:** `HaloDomain/Ports/PreferencesPort.swift`, `HaloApplication/Account/PreferencesStore.swift`, `HaloPlatform/UserDefaultsPreferencesStore.swift`, `FeatureSettings/WhatsNewAndFeedbackView.swift`, `FeatureSettings/SettingsView.swift`, `FeatureSettingsTests/AcknowledgementsTests.swift`, `ios/App/HaloApp.swift`, `ios/UITests/HaloUITests.swift`, `ios/Halo.xcodeproj/project.pbxproj`.
- **Docs:** `docs/ROADMAP.md`, `docs/design/UX_AUDIT.md`, `docs/development/TECH_DEBT.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder (`👤`) or physical device (`📱`)**
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4).
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-16 (DB field encryption):** decide AES-GCM field encryption (`KeychainItem.haloDatabaseKey`) vs plaintext under `completeUntilFirstUserAuthentication` with an ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide `infra/sygnal/` pushkin vs amending ADR-0015; configure Beta/Release push gateway + APNs keys + TestFlight.
- 👤 **UX/ship open questions (D84):** **Q-BRAND** (sign-in illustration; halo disc `AppIcon` landed), **Q-ONBOARD-SERVER**, **Q-L10N**, **Q-APPSTORE** (App Store metadata, privacy policy & support pages), legal review (D38), export compliance (V-LEGAL), privacy nutrition labels ([docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)).
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, NFR-1/NFR-2 XCTest metrics on iPhone 15-class device (`HALO_RUN_PERF_TESTS=1`), MetricKit hang/launch review, and Beta 1 → Beta 2 → 1.0 release.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. Founder resolves §5 items (gates, push gateway / APNs, Q-BRAND sign-in illustration, Q-APPSTORE, legal/export/privacy labels) and runs Beta 1 (internal TestFlight) on a physical device.
2. Post-1.0 backlog (M16): Share extension, App Intents / Siri, Spotlight, Focus filter, widgets, iPad layout, calls (D43).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/ROADMAP.md (§"Remaining work").
All autonomous engineering work for M0–M15, ADR-0022 steps 1–4, and Tech Debt
Phases A–D is complete and merged.

Only founder (👤) and physical-device (📱) items remain in HANDOFF.md §5
(gates, Beta/Release push gateway + TestFlight, Q-BRAND sign-in artwork,
Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE, legal/export/privacy labels, 7-day
AC-U8 soak, and physical-device NFR-1/NFR-2 metrics).
Ask the founder which release or post-1.0 (M16) item to tackle next.
```
