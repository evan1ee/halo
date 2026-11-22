# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `refactor/adr0022-two-manifests` · PRs #1–#54 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10, **M11 (PR #52)**, **M12 (PR #53)**, **M13 (PR #54)**, and **ADR-0022 step 4 (two-manifest consolidation, D86)** are implemented (`refactor/adr0022-two-manifests`). Next: **M14 (Accessibility & localisation + `HaloUITests`)** → **M15 (Ship readiness + Tech Debt Phase D)**. Founder-blocked items in §5.
- **Milestones:** M0–M13 + ADR-0022 steps 1–4 done except founder/device items (G-FFI/G-UNREAD/G-NSE confirmations, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, Q-BRAND sign-in illustration, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (`HaloCore` 165 tests, `HaloApple-Package` all 16 targets on iOS Simulator, `Halo-Debug` app build, `validate-docs.sh`, `check-boundaries.sh` incl. adapter public-API check, `test_check_boundaries.py`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks`). `.build` size dropped from **6.5 GB** to **530 MB** (92% reduction).
- **CI:** PRs #1–#54 merged. Linux CI runs `swift test --package-path ios/Packages/HaloCore -Xswiftc -warnings-as-errors`.

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **ADR-0022 step 4 — two-manifest consolidation (`refactor/adr0022-two-manifests`, D86):**
  - Replaced 20 local `Package.swift` manifests with `ios/Packages/HaloCore` (Linux-buildable: `HaloFoundation`, `HaloDomain`, `HaloApplication`, `HaloTestSupport`) and `ios/Packages/HaloApple` (16 iOS/Apple targets: adapter, persistence, platform, design system, bot rendering, and all 11 `Feature*` targets); all module/target names unchanged.
  - Organized `HaloMatrixAdapter` and `HaloTestSupport` into the 12 matching area folders (`Session`, `Sync`, `RoomList`, `Timeline`, `Media`, `Stickers`, `Encryption`, `Notifications`, `Bots`, `Search`, `Account`, `Support`).
  - Updated `ios/project.yml` + `Halo.xcodeproj`, `scripts/prepush.sh`, `scripts/check_boundaries.py` (target-level manifest + naming + adapter public-API checks) & `test_check_boundaries.py`, `scripts/check-design-tokens.sh`, `scripts/contract-test.sh`, `.github/workflows/swift-linux.yml`, and docs (`AGENTS.md` §5/§13, `MODULE_BOUNDARIES.md`, `DEVELOPMENT_SETUP.md`, `ROADMAP.md`, `TECH_DEBT.md` TD-16 removed).
- **M13 Core-flow polish + ADR-0022 step 3 + TD-11 split + Phase C (`PR #54`, merged `3ce949f`):** extracted `HaloBotRendering`, `FeatureComposer`, `FeatureMedia`, renamed `FeatureOnboarding`; split `TimelineView`/`TimelineViewModel`; S1/S14/S15 onboarding; room-list/timeline/composer polish; `HaloErrorCopy`, `ActionState`, TD-13 sleep removal.
- **M12 Navigation & IA + ADR-0022 step 2 + Phase B (`PR #53`, merged `314c528`):** `PreferencesPort`/`PreferencesStore`, `ChatsRoute`/`ChatsRouter`, `FeatureSearch`, `FeatureProfile`, `App/Composition/*Assembly.swift`, `SettingsConfiguration`, D85 single-stack shell with `.searchable` room list and `@SceneStorage` restoration.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 (all 4 steps complete).

## 4. Modified files (this push)
- **Manifests & package layout:** `ios/Packages/HaloCore/Package.swift`, `ios/Packages/HaloApple/Package.swift`, moved sources/tests under `HaloCore/` and `HaloApple/`, area folders in `HaloMatrixAdapter` and `HaloTestSupport`, removed 20 old `Package.swift` manifests.
- **Project, scripts & CI:** `ios/project.yml`, `ios/Halo.xcodeproj/project.pbxproj`, `scripts/check_boundaries.py`, `scripts/test_check_boundaries.py`, `scripts/prepush.sh`, `scripts/check-design-tokens.sh`, `scripts/contract-test.sh`, `.github/workflows/swift-linux.yml`.
- **Docs:** `AGENTS.md`, `docs/architecture/MODULE_BOUNDARIES.md`, `docs/development/DEVELOPMENT_SETUP.md`, `docs/ROADMAP.md`, `docs/development/TECH_DEBT.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4).
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-16 (DB field encryption):** decide AES-GCM field encryption (`KeychainItem.haloDatabaseKey`) vs plaintext under `completeUntilFirstUserAuthentication` with an ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide `infra/sygnal/` pushkin vs amending ADR-0015; configure Beta/Release push gateway + APNs keys + TestFlight.
- 👤 **UX/ship open questions (D84):** **Q-BRAND** (sign-in illustration; halo disc `AppIcon` landed), **Q-ONBOARD-SERVER**, **Q-L10N**, **Q-APPSTORE** ([docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)).
- 📱 **Long-horizon physical device soak:** 7-day AC-U8 daily-driver soak + Release/TestFlight G-NSE spot check.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. **M14 (Accessibility & localisation + TD-03 `HaloUITests`)** on branch `feat/m14-accessibility-l10n`: VoiceOver pass (`RoomRow` combined element, `.accessibilityActions`, bot-card states), Dynamic Type AX5 + Reduce Motion/Transparency check, `HaloUITests` XCUITest target with `performAccessibilityAudit()`, String Catalog `Localizable.xcstrings`.
2. **M15 (Ship readiness + Tech Debt Phase D)** on branch `feat/m15-ship-readiness`: `PrivacyInfo.xcprivacy` (app + NSE), in-app feedback, What's New sheet, About links, XCTest performance metrics, `bot_action` GRDB migration (TD-08), manual-dispatch macOS build workflow (TD-04).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/ROADMAP.md (§"Remaining work").
M0–M13 and ADR-0022 steps 1–4 (two-manifest HaloCore + HaloApple) are done.

Task: execute M14 (Accessibility & localisation + HaloUITests) on branch
feat/m14-accessibility-l10n, then M15 (Ship readiness + Tech Debt Phase D) on
feat/m15-ship-readiness. Verify every PR with:
  HALO_SIM="iPhone Air" scripts/prepush.sh
  scripts/validate-docs.sh
```
