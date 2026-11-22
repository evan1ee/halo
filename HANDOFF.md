# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `feat/m12-navigation` · PRs #1–#52 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10, **M11 (Design-system foundation + ADR-0022 step 1 + Phase A, PR #52)**, and **M12 (Navigation & IA, D85 + ADR-0022 step 2 + Phase B)** are implemented (`feat/m12-navigation`). Next item is **M13 (Core-flow polish + ADR-0022 step 3 + TD-11 split + Phase C)**. Founder-blocked items in §5.
- **Milestones:** M0–M4, M6–M12 done except founder/device items (G-FFI/G-UNREAD/G-NSE confirmations, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, Q-BRAND sign-in illustration). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (all 13 SwiftPM packages incl. new `FeatureSearch` and `FeatureProfile`, `HaloMatrixAdapter` simulator tests, `Halo-Debug` app build, `validate-docs.sh`, `check-boundaries.sh`, `test_check_boundaries.py`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks`).
- **CI:** PRs #1–#52 merged. Linux CI covers Foundation, Domain (including `TimelineReadTracker`), TestSupport, Application (including `ChatsRouter` and `PreferencesStore`).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **M12 Navigation & IA + ADR-0022 step 2 + Tech Debt Phase B (`feat/m12-navigation`, D85/D86):**
  - `PreferencesPort` (`HaloDomain`), `FakePreferencesPort` (`HaloTestSupport`), `UserDefaultsPreferencesStore` (`HaloPlatform`, unit-tested), and observable `PreferencesStore` (`HaloApplication`, unit-tested) — eliminated all `AppPreferences()` calls from `ios/App/` (TD-02).
  - `ChatsRoute` & `ChatsRouter` in `HaloApplication/Navigation/` with push deduplication, Codable `@SceneStorage` state restoration, and `pruneInvalidRooms(joinedRoomIDs:)` (unit-tested in `ChatsRouterTests`, NAVIGATION §2/§4).
  - ADR-0022 step 2: extracted `FeatureSearch` (`MessageSearchView`, `MessageSearchResultsSection`, `MessageSearchViewModelTests`) and `FeatureProfile` (`UserProfileView`, `UserProfileViewModel`, `ProfileSettings`, `ProfileSettingsView`, moved tests); split `AppRoot` (now 160 lines) into `ios/App/Composition/{Session,Chats,Settings,Notifications,Bots}Assembly.swift`; replaced `SettingsView`'s 25-closure init with `SettingsConfiguration` model factory (TD-10).
  - D85 single-stack shell in `HaloApp.swift`: large title "Chats", top-leading avatar → pushed Settings, top-trailing compose (`square.and.pencil`) → New chat sheet (UX-01), more menu (`ellipsis.circle`) with filters/Stickers/Activity, `.searchable` room list with embedded `MessageSearchResultsSection`, pushed Activity & Sticker library, `@SceneStorage` path restoration, unified routing through `ChatsRouter`.
- **M11 Design-system foundation + ADR-0022 step 1 + Tech Debt Phase A (`PR #52`, merged `59ed32d`):**
  - Asset catalogues (`Colors.xcassets` + founder's halo disc `AppIcon`), `HaloColor`/`Spacing`/`Radius`/`Typography`/`Motion`/`Feedback`, WCAG AA contrast test (AC-UX-2), shared components (`UnreadIndicator`, `RoomRow`, `HaloBanner`, `LoadingState`, `ErrorState`, `EmptyState`), token migration + `check-design-tokens.sh` (AC-UX-1), naming gate, `.swiftlint.yml` + `.swift-format` (TD-06), `@unchecked Sendable` justifications (TD-14), slimmed ROADMAP queue (TD-09), Swift 6.2 Linux `sending` fix in `NotificationProcessorTests`.
- **Module layout v2 & UX/ship-readiness roadmap (`5f1c0c5`):** accepted ADR-0022 (D86), added `UX_AUDIT.md`, `TECH_DEBT.md`, D84/D85, and M11–M15 queue.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84:** Apple-native look and feel north star driving M11–M15.
- **D85 (supersedes D50):** single `NavigationStack`, Messages-style shell (avatar → Settings, compose, more menu, `.searchable` list).
- **D86 (ADR-0022):** module layout v2 in four steps; naming `Halo<Layer>` / `Feature<Area>`.

## 4. Modified files (this push)
- **Domain / Application / Platform / TestSupport:** `HaloDomain/Ports/PreferencesPort.swift`, `HaloTestSupport/FakePreferencesPort.swift`, `HaloPlatform/UserDefaultsPreferencesStore.swift`, `HaloPlatformTests/UserDefaultsPreferencesStoreTests.swift`, `HaloApplication/Account/PreferencesStore.swift`, `HaloApplication/Navigation/ChatsRoute.swift`, `HaloApplicationTests/ChatsRouterTests.swift`.
- **New feature packages (ADR-0022 step 2):** `ios/Packages/Features/FeatureSearch/**`, `ios/Packages/Features/FeatureProfile/**`.
- **Updated features & App composition:** `ios/App/HaloApp.swift`, `ios/App/AppRoot.swift`, `ios/App/Composition/{Session,Chats,Settings,Notifications,Bots}Assembly.swift`, `FeatureRoomList`, `FeatureRoomDetails`, `FeatureSettings`, `FeatureBotActivity`, `ios/project.yml`, `ios/Halo.xcodeproj/project.pbxproj`, `scripts/prepush.sh`.
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
1. **M13 (Core-flow polish + ADR-0022 step 3 + TD-11 split + Tech Debt Phase C)** on branch `feat/m13-core-flow-polish`:
   - ADR-0022 step 3 + TD-11 split first: extract `HaloBotRendering` (`BotCardView`, `HTMLText`), `FeatureComposer` (composer, attachments, mentions), `FeatureMedia` (global gallery + one shared photo viewer + Quick Look); rename `FeatureAuth` → `FeatureOnboarding`; split `TimelineViewModel`/`TimelineView` below 600 lines per file.
   - First-run flow (S1 welcome + homeserver inline help + S14 notification priming + S15 checklist).
   - Room list polish (`.refreshable`, Mail-style swipe icons + labels, compact invite cards), Timeline polish (bubble grouping, swipe-to-reply + haptic, double-tap quick 👍 + reaction bar, material jump pills, typing indicator), Composer polish (6-line growth, attachment menu, paste image), Room details/profiles Contacts-style header, Copy pass (`HaloError` user-facing map), and TD-01/TD-07/TD-13.
2. **ADR-0022 step 4** (two-manifest consolidation: `HaloCore` + `HaloApple`) right after M13 merges.
3. **M14** (accessibility, String Catalog, `HaloUITests`) → **M15** (privacy manifest, feedback, What's New, perf budgets).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, docs/ROADMAP.md (§"Remaining work"),
docs/design/SCREEN_SPECIFICATIONS.md and docs/adr/0022-module-layout-v2.md.
M0–M12 (including ADR-0022 steps 1–2 and Tech Debt Phases A–B) are done.

Task: implement M13 on branch feat/m13-core-flow-polish:
1. ADR-0022 step 3 + TD-11 split first: HaloBotRendering, FeatureComposer,
   FeatureMedia (one shared photo viewer), rename FeatureAuth -> FeatureOnboarding,
   split TimelineViewModel/TimelineView below 600 lines per file.
2. First-run flow (S1 welcome + homeserver help, S14 notification priming),
   room list/timeline/composer/room-details polish, HaloError copy pass, and
   Tech Debt Phase C (TD-01, TD-07, TD-13).
3. Verify with HALO_SIM="iPhone Air" scripts/prepush.sh, scripts/validate-docs.sh,
   and simulator Light/Dark/AX5 screenshots.
```
