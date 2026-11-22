# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `feat/m11-design-system` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10 done; **M11 (Design-system foundation + ADR-0022 step 1 + Tech Debt Phase A)** implemented on `feat/m11-design-system` (done except founder item `👤 Q-BRAND`). Next item is **M12 (Navigation & IA, D85 + ADR-0022 step 2 + Tech Debt Phase B)**. Founder-blocked items in §5.
- **Milestones:** M0–M4, M6–M10 done (G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation); M5 done except Beta/Release push gateway + TestFlight and the 7-day AC-U8 soak; M11 done except `Q-BRAND`. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (all 11 SwiftPM packages + `HaloMatrixAdapter` simulator tests + `Halo-Debug` app build + `validate-docs.sh` + `check-boundaries.sh` + `test_check_boundaries.py` + `check-design-tokens.sh` + `swiftlint --strict` + `gitleaks`) — run and verified before PR merge.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain (now including `TimelineReadTracker`), TestSupport, Application; Apple packages and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **M11 Design-system foundation + ADR-0022 step 1 + Tech Debt Phase A (`feat/m11-design-system`, D84/D86):**
  - ADR-0022 step 1: fixed stale `AGENTS.md` §3/§13 paths, moved `TimelineReadTracker` + pure tests to `HaloDomain/ReadState/` (covered by Linux CI), organized `HaloDesignSystem/{Tokens,Components,Media}/` and `ios/App/{Resources,Support}/` + `project.yml`.
  - Naming gate (`MODULE_BOUNDARIES.md` §1): enforced `Feature<Area>`, `Halo<Layer>`, and no module/type name collision in `scripts/check_boundaries.py`, unit-tested in `scripts/test_check_boundaries.py`.
  - Asset catalogues: `HaloDesignSystem` `Colors.xcassets` (all 16 semantic tokens in Light/Dark/Increase Contrast) and `ios/App/Resources/Assets.xcassets` (`AccentColor` + founder's 1024 pt halo disc `AppIcon` light/dark/tinted, `Q-BRAND`).
  - Tokens & contrast gate: `HaloColor`, `HaloSpacing`, `HaloRadius`, `HaloTypography`, `HaloMotion`, `HaloFeedback`; `ColorContrastTests` verifies ≥ 4.5:1 WCAG AA across Light/Dark/Increase Contrast on the compiled asset catalogue (AC-UX-2).
  - Shared components (`UnreadIndicator`, `RoomRow`, `HaloBanner`, `LoadingState`, `ErrorState`, `EmptyState` with Light/Dark/AX5 `#Preview`s); replaced all raw system colours and fixed font sizes in `Features/` and `ios/App/`; fixed `SignInView` AX5 truncation via `ScrollView` (verified in Light/Dark/AX5 on `iPhone Air`); added `scripts/check-design-tokens.sh` to `scripts/prepush.sh` (AC-UX-1).
  - Tech Debt Phase A: `.swiftlint.yml` + `.swift-format` (TD-06, D62, fixed 6 force-unwraps in production code), `@unchecked Sendable` justifications in `SessionCoordinator` and `NotificationService` (TD-14), slimmed `docs/ROADMAP.md` queue with M0–M10 appendix (TD-09).
- **Module layout v2 & UX/ship-readiness roadmap (`5f1c0c5`, docs only):** accepted ADR-0022 (D86), added `UX_AUDIT.md`, `TECH_DEBT.md`, D84/D85, and M11–M15 queue.
- **App-switcher privacy blur (`8da66aa`, `D61`, `SECURITY §4`):** `AppPreferences.privacyBlur`, Settings → Privacy toggle, and `.ultraThinMaterial` veil in `HaloApp`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 / D79 / D80 (ADR-0020):** encrypted-room SDK counts decide; identity and timeline-index read ordering (`TimelineReadTracker` now in `HaloDomain/ReadState/`).
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84:** Apple-native look and feel north star driving M11–M15.
- **D85 (supersedes D50):** single `NavigationStack`, Messages-style shell (avatar → Settings, compose, more menu, `.searchable` list).
- **D86 (ADR-0022):** module layout v2 in four steps; naming `Halo<Layer>` / `Feature<Area>`.

## 4. Modified files (this push)
- **Layout & tooling:** `AGENTS.md`, `ios/project.yml`, `ios/Halo.xcodeproj/project.pbxproj`, `ios/App/Support/*`, `scripts/check_boundaries.py`, `scripts/test_check_boundaries.py`, `scripts/check-design-tokens.sh`, `scripts/prepush.sh`, `.swiftlint.yml`, `.swift-format`.
- **Domain & concurrency:** `ios/Packages/HaloDomain/Sources/HaloDomain/ReadState/TimelineReadTracker.swift`, `ios/Packages/HaloDomain/Tests/HaloDomainTests/TimelineReadTrackerTests.swift`, `ios/Packages/HaloDomain/Sources/HaloDomain/RoomList/RoomDetails.swift`, `ios/Packages/HaloDomain/Sources/HaloDomain/Ports/ChatCreationPort.swift`, `ios/Packages/HaloApplication/Sources/HaloApplication/Session/SessionCoordinator.swift`, `ios/Packages/HaloApplication/Tests/HaloApplicationTests/NotificationProcessorTests.swift` (Swift 6.2 Linux `sending` fix), `ios/NotificationService/NotificationService.swift`, `ios/Packages/HaloMatrixAdapter/Sources/HaloMatrixAdapter/MatrixRoomListPort.swift`.
- **Design system & assets:** `ios/App/Resources/Assets.xcassets/**`, `ios/Packages/HaloDesignSystem/**` (`Tokens/`, `Components/`, `Media/`, `Resources/Colors.xcassets/`, `ColorContrastTests.swift`).
- **Features & App token migration:** `ios/App/HaloApp.swift`, `ios/Packages/Features/{FeatureAuth,FeatureBotActivity,FeatureRoomDetails,FeatureRoomList,FeatureSettings,FeatureStickers,FeatureTimeline}/**`.
- **Docs:** `docs/ROADMAP.md`, `docs/design/DESIGN_SYSTEM.md`, `docs/design/UX_AUDIT.md`, `docs/development/TECH_DEBT.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4).
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption (`KeychainItem.haloDatabaseKey`) or accept plaintext under `completeUntilFirstUserAuthentication` with an ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide `infra/sygnal/` pushkin vs amending ADR-0015; configure Beta/Release push gateway + APNs keys + TestFlight.
- 👤 **UX/ship open questions (D84):** **Q-BRAND** (final icon/artwork; placeholder `AppIcon` landed in M11), **Q-ONBOARD-SERVER**, **Q-L10N**, **Q-APPSTORE** ([docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)).
- 📱 **Long-horizon physical device soak:** 7-day AC-U8 daily-driver soak + Release/TestFlight G-NSE spot check.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. **M12 (Navigation & IA, D85 + ADR-0022 step 2 + Tech Debt Phase B)** on branch `feat/m12-navigation`:
   - ADR-0022 step 2: routes into `HaloApplication/Navigation/` (`ChatsRoute`, unit-tested); split `AppRoot` into `App/Composition/{Session,Chats,Settings,Notifications,Bots}Assembly.swift`; extract `FeatureSearch` and `FeatureProfile`.
   - Tech Debt Phase B: `PreferencesPort` + observable store (TD-02); move bot-allowlist sync, diagnostics and cache logic out of `AppRoot` into `HaloApplication`, replace Settings 25-closure init with a settings model factory (TD-10).
   - D85 single-stack shell: large title "Chats", compose button top-trailing (`square.and.pencil`), avatar top-leading → pushed Settings, more menu (`ellipsis.circle`) with filters/Stickers/Activity, `.searchable` room list with "Messages" section, `@SceneStorage` state restoration, one unified router.
2. **M13** (ADR-0022 step 3 + TD-11 split → first-run flow + S14 priming → room list/timeline/composer/details polish → copy pass + TD-01/TD-07/TD-13).
3. **ADR-0022 step 4** (two-manifest consolidation) right after M13 merges.
4. **M14** (accessibility, String Catalog, `HaloUITests`) → **M15** (privacy manifest, feedback, What's New, perf budgets).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, docs/ROADMAP.md (§"Remaining work"),
docs/design/NAVIGATION.md (§1, D85) and docs/adr/0022-module-layout-v2.md.
M0–M11 (plus ADR-0022 step 1 and Tech Debt Phase A) are done.

Task: implement M12 on branch feat/m12-navigation:
1. ADR-0022 step 2: ChatsRoute in HaloApplication/Navigation/, App/Composition/
   split, extract FeatureSearch and FeatureProfile with moved tests.
2. Tech Debt Phase B: PreferencesPort + observable store (TD-02); move
   allowlist/diagnostics/cache logic into HaloApplication and replace Settings'
   closure bag with a model factory (TD-10).
3. D85 single-stack shell: large title "Chats", top-trailing compose button,
   avatar → pushed Settings, more menu (filters/Stickers/Activity), .searchable
   room list + "Messages" section, @SceneStorage state restoration, one router.
4. Verify with HALO_SIM="iPhone Air" scripts/prepush.sh, scripts/validate-docs.sh,
   and simulator Light/Dark/AX5 screenshots.
```
