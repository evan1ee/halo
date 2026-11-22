# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `feat/m14-accessibility-l10n` · PRs #1–#55 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10, **M11–M14** (Design-system foundation, D85 Navigation & IA, Core-flow polish, Accessibility & localisation + `HaloUITests`), and **ADR-0022 steps 1–4** (two-manifest `HaloCore` + `HaloApple`, D86) + Tech Debt Phases A–C + TD-03 are implemented (`feat/m14-accessibility-l10n`). Next: **M15 (Ship readiness + remaining Tech Debt Phase D: TD-04, TD-08)**. Founder-blocked items in §5.
- **Milestones:** M0–M14 done except founder/device items (G-FFI/G-UNREAD/G-NSE confirmations, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, Q-BRAND sign-in illustration, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (`HaloCore` 165 tests, `HaloApple-Package` all 16 targets on iOS Simulator incl. `RoomRowAccessibilityTests`, `Halo-Debug` app build, `HaloUITests` with `performAccessibilityAudit()`, `validate-docs.sh`, `check-boundaries.sh`, `test_check_boundaries.py`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks`).
- **CI:** PRs #1–#55 merged. Linux CI runs `swift test --package-path ios/Packages/HaloCore -Xswiftc -warnings-as-errors`.

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **M14 Accessibility & localisation + `HaloUITests` (`feat/m14-accessibility-l10n`, TD-03, UX-10/UX-11/SR-07):**
  - VoiceOver pass (DESIGN_SYSTEM §9): `RoomRow` combined accessible element (`RoomRow.accessibilitySummary`, unit-tested) with 44 pt minimum height; `.accessibilityActions` on `RoomListView` (Mark read/unread, Mute, Favourite) and `TimelineMessageRowView` (Reply, React 👍, More reactions, Edit, Delete); `BotCardView` 44×44 tick hit targets and explicit state values.
  - Dynamic Type AX5 fix: replaced clipped `.roundedBorder` text fields in `SignInView` with Dynamic-Type-friendly padded containers (caught and verified by `performAccessibilityAudit()`).
  - XCUITest target `HaloUITests` (`ios/UITests/HaloUITests.swift`, `ios/project.yml`, `scripts/prepush.sh`): automated `performAccessibilityAudit()` on root and inline-help screens + optional golden-path test against `infra/dev`.
  - String Catalog `ios/App/Resources/Localizable.xcstrings` (`sourceLanguage: "en"`, plural rules for `%lld unread messages`, `%lld members`), validated by `RoomRowAccessibilityTests.stringCatalogIsValid`.
- **ADR-0022 step 4 — two-manifest consolidation (`PR #55`, merged `433e337`, D86):** replaced 20 `Package.swift` manifests with `HaloCore` (Linux) and `HaloApple` (16 iOS/Apple targets), organized `HaloMatrixAdapter` and `HaloTestSupport` into 12 matching area folders; `.build` disk footprint dropped from **6.5 GB** to **530 MB** (92% reduction).
- **M13 Core-flow polish + ADR-0022 step 3 + TD-11 split + Phase C (`PR #54`, merged `3ce949f`):** extracted `HaloBotRendering`, `FeatureComposer`, `FeatureMedia`, renamed `FeatureOnboarding`; split `TimelineView`/`TimelineViewModel`; S1/S14/S15 onboarding; room-list/timeline/composer polish; `HaloErrorCopy`, `ActionState`, TD-13 sleep removal.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 (all 4 steps complete).

## 4. Modified files (this push)
- **Accessibility & UI:** `HaloDesignSystem/Components/RoomRow.swift`, `HaloBotRendering/BotCardView.swift`, `FeatureRoomList/RoomListView.swift`, `FeatureTimeline/TimelineMessageRowView.swift`, `FeatureOnboarding/SignInView.swift`.
- **Localisation & Tests:** `ios/App/Resources/Localizable.xcstrings`, `ios/UITests/HaloUITests.swift`, `HaloDesignSystemTests/RoomRowAccessibilityTests.swift`, `ios/project.yml`, `ios/Halo.xcodeproj/project.pbxproj`, `scripts/prepush.sh`.
- **Docs:** `docs/ROADMAP.md`, `docs/design/UX_AUDIT.md`, `docs/development/TECH_DEBT.md`, `HANDOFF.md`.

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
1. **M15 (Ship readiness + Tech Debt Phase D)** on branch `feat/m15-ship-readiness`: `PrivacyInfo.xcprivacy` (app + NSE), in-app feedback (Settings → "Send feedback" with optional diagnostics `.zip`), What's New sheet once per marketing version, About screen links, XCTest launch/list performance metrics, `bot_action` GRDB migration (TD-08), manual-dispatch macOS build workflow (TD-04).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/ROADMAP.md (§"Remaining work").
M0–M14 and ADR-0022 steps 1–4 are done.

Task: execute M15 (Ship readiness + Tech Debt Phase D: PrivacyInfo.xcprivacy
for app & NSE, in-app feedback, What's New sheet, About links, XCTest metrics,
bot_action GRDB migration TD-08, manual-dispatch macOS workflow TD-04) on
branch feat/m15-ship-readiness. Verify with:
  HALO_SIM="iPhone Air" scripts/prepush.sh
  scripts/validate-docs.sh
```
