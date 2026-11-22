# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `feat/m13-core-flow-polish` · PRs #1–#53 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10, **M11 (PR #52)**, **M12 (PR #53)**, and **M13 (Core-flow polish + ADR-0022 step 3 + TD-11 split + Phase C)** are implemented (`feat/m13-core-flow-polish`). Next: **ADR-0022 step 4 (two-manifest consolidation)** → **M14 (Accessibility & localisation)** → **M15 (Ship readiness)**. Founder-blocked items in §5.
- **Milestones:** M0–M13 done except founder/device items (G-FFI/G-UNREAD/G-NSE confirmations, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, Q-BRAND sign-in illustration, Q-ONBOARD-SERVER). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Checks (this branch):** `HALO_SIM="iPhone Air" scripts/prepush.sh` (all 18 SwiftPM packages incl. `HaloBotRendering`, `FeatureOnboarding`, `FeatureComposer`, `FeatureMedia`, `HaloMatrixAdapter` simulator tests, `Halo-Debug` app build, `validate-docs.sh`, `check-boundaries.sh`, `test_check_boundaries.py`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks`).
- **CI:** PRs #1–#53 merged. Linux CI covers Foundation, Domain (incl. `TimelineReadTracker` and `HaloErrorCopy`), TestSupport, Application (incl. `ChatsRouter` and `PreferencesStore`).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log`.
- **M13 Core-flow polish + ADR-0022 step 3 + TD-11 split + Tech Debt Phase C (`feat/m13-core-flow-polish`, D84/D86):**
  - ADR-0022 step 3: extracted `HaloBotRendering` (`BotCardView`, `HTMLText` + `HTMLTextTests`), `FeatureComposer` (`ComposerBarView` + `ComposerStateTests`), `FeatureMedia` (`GlobalMediaGallery` + unified `HaloDesignSystem.PagedPhotoViewer` + `QuickLookView`), renamed `FeatureAuth` → `FeatureOnboarding`.
  - TD-11 split: split `TimelineView.swift` (1,280 → 4 files ≤ 445 lines) and `TimelineViewModel.swift` (1,432 → 4 files ≤ 482 lines).
  - First-run flow (S1, S14, S15): `SignInView` value statement + inline `"What's a homeserver?"` help; `NotificationPrimingView` (S14, replaces immediate auto-prompt in `HaloApp`, AC-UX-7, UX-07); `FirstRunChecklistView` (S15).
  - Core-flow polish: room list `.refreshable` + Mail-style swipe actions with SF Symbols + semantic tints (UX-12); timeline swipe-to-reply + `HaloFeedback(.swipeThreshold)`, double-tap quick 👍 + `HaloFeedback(.reaction)`, `.regularMaterial` jump pills without custom shadows; composer 6-line growth + attachment menu + paste image + `HaloFeedback(.send)`.
  - Tech Debt Phase C: `HaloErrorCopy` plain-language error map (UX-15, unit-tested in `HaloErrorCopyTests`), `ActionState` double-tap guard (TD-07, unit-tested in `ActionStateTests`), removed 1.5 s sleep workaround in `RoomDetailsViewModel.load()` (TD-13).
- **M12 Navigation & IA + ADR-0022 step 2 + Tech Debt Phase B (`PR #53`, merged `314c528`):** `PreferencesPort` + `PreferencesStore` (TD-02), `ChatsRoute`/`ChatsRouter`, `FeatureSearch`, `FeatureProfile`, `App/Composition/*Assembly.swift`, `SettingsConfiguration` (TD-10), D85 single-stack shell with `.searchable` room list and `@SceneStorage` restoration.
- **M11 Design-system foundation + ADR-0022 step 1 + Tech Debt Phase A (`PR #52`, merged `59ed32d`):** asset catalogues (incl. founder's halo disc `AppIcon`), tokens + WCAG AA contrast test, shared components, `HaloFeedback`, token gate, naming gate, SwiftLint/swift-format (TD-06), TD-14, TD-09.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D86), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 in 4 steps (steps 1–3 done, step 4 next).

## 4. Modified files (this push)
- **New packages (ADR-0022 step 3):** `ios/Packages/HaloBotRendering/**`, `ios/Packages/Features/FeatureComposer/**`, `ios/Packages/Features/FeatureMedia/**`, `ios/Packages/Features/FeatureOnboarding/**` (renamed from `FeatureAuth`, plus `NotificationPrimingView.swift` & `FirstRunChecklistView.swift`).
- **Core / DesignSystem:** `HaloDomain/Errors/HaloErrorCopy.swift`, `HaloDomainTests/HaloErrorCopyTests.swift`, `HaloDesignSystem/Media/{PagedPhotoViewer,QuickLookView}.swift`, `HaloDesignSystem/Tokens/ActionState.swift`, `HaloDesignSystemTests/ActionStateTests.swift`.
- **Features & App:** `FeatureTimeline` (TD-11 split into 8 focused files + gestures/haptics), `FeatureRoomList` (`.refreshable` + Mail swipe labels), `FeatureRoomDetails` (TD-13 sleep removal), `ios/App/{HaloApp,AppRoot,Composition/*}.swift`, `ios/project.yml`, `ios/Halo.xcodeproj/project.pbxproj`, `scripts/prepush.sh`.
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
1. **ADR-0022 step 4 (two-manifest consolidation)** on branch `refactor/adr0022-two-manifests` right after M13 merges: consolidate `HaloFoundation`/`HaloDomain`/`HaloApplication`/`HaloTestSupport` into `ios/Packages/HaloCore`, and Apple packages/features into `ios/Packages/HaloApple` with matching area folders, updating `ios/project.yml`, `scripts/prepush.sh`, `scripts/check_boundaries.py`, `.github/workflows/swift-linux.yml`, and docs.
2. **M14 (Accessibility & localisation)** on branch `feat/m14-accessibility-l10n`: VoiceOver pass, Dynamic Type AX5 pass, `HaloUITests` with `performAccessibilityAudit()`, String Catalog `Localizable.xcstrings`.
3. **M15 (Ship readiness)** on branch `feat/m15-ship-readiness`: `PrivacyInfo.xcprivacy` (app + NSE), in-app feedback, What's New sheet, About links, XCTest metrics, Tech Debt Phase D (`bot_action` table TD-08, manual macOS workflow TD-04).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, docs/ROADMAP.md (§"Remaining work"),
and docs/adr/0022-module-layout-v2.md.
M0–M13 (including ADR-0022 steps 1–3 and Tech Debt Phases A–C) are done.

Task: execute ADR-0022 step 4 (two-manifest consolidation) as one mechanical PR
with no behaviour change, then proceed immediately to M14 (Accessibility &
localisation + HaloUITests) and M15 (Ship readiness + Phase D tech debt).
Verify every PR with HALO_SIM="iPhone Air" scripts/prepush.sh and
scripts/validate-docs.sh.
```
