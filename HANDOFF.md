# Halo — Session Handoff

Last updated: 2026-11-24 · Branch: `fix/unread-badge-consistency` · PRs #1–#87 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** all autonomous work across M0–M16, ADR-0022, Tech Debt A–D (including TD-12), the Halo Sygnal pushkin (`infra/sygnal/`, R-24), and release documentation (`docs/release/`, D115) is complete; all open product decisions in `OPEN_QUESTIONS.md` are resolved (`D108–D117`). Physical iPhone 16 `HaloUITests`, NFR-1 cold launch (0.357 s responsive), timeline memory (76.8 MB peak), D95 10× room-opening, live sends, image-scroll & mid-scroll jump-to-bottom (PR #87), pushed full-bleed Room info page, Voice messages, Share extension (`V-SHARE-1`), Focus filter, and Siri/Spotlight all passed; P0 badge/widget/background-sync fixes (PR #85) landed. The roadmap has been slimmed and expanded with **M17–M19** in [docs/ROADMAP.md](docs/ROADMAP.md). External-account / legal (`👤`) and remaining physical-device (`📱`) items remain in §5.
- **Milestones:** M0–M16 done except external/device items (deploy `infra/sygnal/` + APNs keys + TestFlight, 7-day AC-U8 soak, interactive Xcode/Instruments NFR-2 scroll hitch + 300-room + MetricKit run, Q-KLIPY-PROD portal request, publish `docs/release/` privacy/support URLs, final Beta 2 brand artwork, legal/export review). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`), physical iPhone 16 (`00008140-000222592ED0801C`, iOS 27.2.1).
- **Last checks (`fix/unread-badge-consistency`):** `swift test` HaloCore (374 tests, also on Linux Swift 6.2), all 16 HaloApple suites, app build, `infra/sygnal` unit tests (7), docs, boundaries, design tokens, swiftlint (0 violations) and gitleaks passed; iPhone 16 `testUnreadBadgePersistsAcrossOpenCloseCycles` passed (10 cycles). `prepush.sh` passed in full (device-only UI tests skip themselves).
- **CI:** PRs #1–#87 merged. Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **Unread badge, widgets and background sync (D118, 2026-11-24, `fix/unread-badge-consistency`):**
  - Root causes: gateway down and Halo's pushkin never able to send (asyncio awaited on Twisted); dev ran the stock pushkin; background launches did nothing (handlers set in a view) and reported done before the badge was written; pre-sync evaluations overwrote what the NSE had counted; unordered badge writes; the NSE counted late pushes twice and raced itself; a sticky foreground flag; no refresh fallback; a widget reload on every open/close spent iOS's budget.
  - Verified on iPhone 16 via SpringBoard's icon value: pushes 8→10 suspended, 10→11 terminated; read elsewhere 11→0 in ~5 s suspended and from a cold background launch; 10 open/close cycles unchanged. A Focus with "Hide Notification Badges" hid the icon badge on the founder's phone (value was right throughout).
- **S11 offline read (D119, 2026-11-24, same branch):** the own-latest case of `SDK_UNREAD_AFTER_READ` discarded a read that couldn't be sent when the SDK's latest event still was the user's own join. Real-server scenarios 8×: the ordering came up in 3 runs, S11 passed in all 8; one run failed later at S29 (see §5). Also fixed PR CI: a test closure Swift 6.2 on Linux rejects, and a gitleaks false positive.
- **Room info as pushed full-bleed navigation page (2026-11-24, `main`):**
  - Replaced Room info `.sheet` presentation (timeline avatar button and room-list context menu) with `ChatsRoute.roomInfo(RoomID)`, `ChatsRouter.openRoomInfo(_:)`, `ChatsRouter.removeRoom(_:)`, and `RoomInfoPresentation.page` (keeping `.inspector` on regular-width iPad).
  - Removed the nested `NavigationStack` from `RoomDetailsView` and matched the conversation page's transparent, title-free header with full-bleed edge-to-edge scrolling (`.scrollEdgeEffectHidden(true, for: .top)`); verified with `HaloUITests.testRoomInfoOpensAsPushedPage` on physical iPhone 16.
- **Scroll-safe timeline long-press & image/map tap style + iPhone 16 verification (2026-11-24, PR #87):**
  - Removed SwiftUI `.simultaneousGesture(LongPressGesture)` + touch-down `.scaleEffect(0.96)` (which flashed a tap/press effect and interfered with scrolling over images, maps, and messages) and replaced it with a UIKit-backed `UILongPressGestureRecognizer` (`ScrollSafeLongPressModifier`, `cancelsTouchesInView = false`, `delaysTouchesBegan = false`, simultaneous with `UIScrollView`) plus no-highlight `ScrollFriendlyTapButtonStyle` on images, maps (`LocationCardView`), and reply quotes.
  - Made `jump-to-bottom` interrupt ongoing deceleration synchronously on the tap frame before converging; added and passed `HaloUITests.testTimelineImageScrollAndJumpToBottomWhileScrolling` on physical iPhone 16 (`00008140-000222592ED0801C`).

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D119), [docs/adr/README.md](docs/adr/README.md).
- **D118:** one unread count for icon, widgets and list (E6, recomputed NSE badge, ordered writes, background refresh).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 (all 4 steps complete).
- **D95:** a room opens at its newest message; the first unread message stays marked and "Jump to unread" goes up to it.
- **D97:** one input area: keyboard and Halo's panels swap under the composer without a jump; composer and panels are independent.
- **D100:** attachment panel tabs Gallery · File · Location · Poll; location and polls via the SDK.
- **D101:** Article tab: Markdown editor sending one formatted text message through the existing path.
- **D102:** the area under the composer owns the keyboard height, moving with the keyboard's measured curve; swaps can't move the composer (no interactive keyboard drag).
- **D103:** restore a stored session without server discovery (fast, offline-capable launch).
- **D104:** the Focus filter narrows the chat list only when Settings → Follow Focus filters is on (default off).
- **D106:** pasted images become pending photos; attachment tabs fit narrow iPhones.
- **D105:** privacy cover only while leaving (no icon); cached own avatar; Room-info inspector on iPad only (fixes the iPhone pop/crash).
- **D99:** Telegram composer layout (face icon, mic / ↑ / ↓, send in field) and voice messages as `m.audio`.
- **D98:** GIF/sticker search via KLIPY from the device; sent as E2EE links to unmodified KLIPY URLs (no re-hosting); favourites/recents on device.
- **D96:** the accessibility audit skips contrast under the floating search field and `element == nil` `.contrast`/`.textClipped` while that field is on screen; every resolved element above it still fails.

## 4. Modified files (this push)
- **S11 / CI:** `ReadState.swift`, policy, property and scenario tests, `NotificationProcessorTests`, `AttentionCacheTests`, `.gitleaksignore`, `UNREAD_STATE`, `UNREAD_REGRESSION_TESTS`, `DECISION_LOG`. The rest of the branch:
- **Core:** `ReadState.swift` (E6), `BadgePort`, `RoomListPort`, `NotificationRecordPort`, `ReadStateCoordinator`, `RoomListCoordinator`, `NotificationProcessor`, `SyncCoordinator`, `BackgroundRefresh` (new), `ReadReceiptCoordinator`, fakes, tests.
- **Apple / app:** `SystemBadge.swift` (`AttentionCache`), `BackgroundRefreshScheduler` (new), `MatrixRoomListPort`, `MatrixSessionPort`, `NotificationRecordStore`, NSE, widgets, `HaloApp`, `AppRoot`, `SessionAssembly`, both `Info.plist`s, `HaloUITests`.
- **Infra / docs:** `infra/sygnal/`, `infra/dev/` (Halo pushkin), `UNREAD_STATE`, `PUSH_NOTIFICATIONS`, `BACKGROUND_EXECUTION`, `PORTS_CONTRACT`, `SYNC_ENGINE`, ADR-0015, `DECISION_LOG`, `OPEN_QUESTIONS`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Engineering (not blocking)**
- **Accessibility audit is flaky on the signed-in simulator (failed on `main` too):** `testLaunchRootScreenPassesAccessibilityAudit`, "Potentially inaccessible text" without an element; it failed earlier on 2026-11-24 and passed in the last `prepush.sh` run. Cause unknown.
- **Dev APNs stall (2026-11-24, 15:05–15:19 UTC):** APNs accepted pushes the iPhone never acted on (alerts and silent ones), then delivery resumed without a change; a later silent push also had no effect within 12 s (iOS throttles them; opening healed it). Cause unknown.
- **Contract failure that also fails on `main` (b1a280b):** `AdapterContractTests.readMarkers` (60 s timeout).
- **S29 server flake (1 of 8 runs):** Synapse rotated its push counts 90 ms before the receipt arrived and kept reporting 3 past the test's 30 s wait; its database had the right count (1) afterwards. Not a Halo rule.
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).

**Needs the founder (`👤`) or physical device (`📱`)**
- 👤 **Q-KLIPY-PROD:** the KLIPY key is a testing key (100 requests/hour); request production access in KLIPY's Partner Panel before Beta 1.
- 📱 **UI tests on devices:** the iPhone 16 (`00008140-000222592ED0801C`, signed in as contractpeer on the LAN dev server) runs `HaloUITests` (composer, empty room, launch). The iPhone 17e still exited with code 74.
- 📱 **Location, polls and articles:** pinned location, poll, Markdown article, and KLIPY GIF live sends verified in Halo on iPhone 16 (`testLiveSendsLocationPollArticleAndKlipy`); still open: current-location send + Element interoperability check.
- 📱 **Voice messages on a device:** record, cancel, send, and playback verified green on iPhone 16; still open: Element interoperability check.
- 📱 **Composer panels on a device:** keyboard ↔ panel swap and KLIPY GIF inline send/play verified on iPhone 16; still open: iPad floating/hardware keyboard, composer following keyboard from idle, and KLIPY GIF link interoperability in Element (AC-CP3).
- 📱 **Opening rooms on the device (D95):** S10 10× room-opening check verified green on iPhone 16 (`testRoomOpeningLandsAtNewestTenTimes`, 10/10 at newest message, no spinner); still open: notification-tap / Spotlight entry and iPad split view.
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (Beta/Release push gateway deploy):** deploy `infra/sygnal/` (D112) with APNs keys, verify V-PUSH-5 live, and upload Beta 1 to TestFlight.
- 👤 **UX/ship external items (D84, D115):** publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md` with founder domain/contact, final Beta 2 brand artwork (`Q-BRAND`), legal review (D38), export compliance (V-LEGAL), and App Store Connect privacy nutrition labels.
- 📱 **Drag and drop (iPad):** drop a photo, a PDF and a link from Photos/Files/Safari into an open chat, and drag text, a photo, and a file out of a chat (also Split View with another app); a > 50 MiB file shows the size error.
- 📱 **Keyboard shortcuts (iPad/hardware keyboard):** ⌘N, ⌘,, ⌘F, ⌘1–⌘6 work and ⌘F focuses the search field.
- 📱 **Widgets in the background (D118):** icon verified live; the widget refreshed on open, but on the founder's phone iOS ignored every background reload (extension and app) on 2026-11-24, most likely a spent daily reload budget. Re-check with Settings → Developer → WidgetKit Developer Mode, or after a day. iOS's own scheduling of the app refresh was only simulated (debugger).
- 📱 **iPad on a device / dev homeserver (D91):** only the signed-out screen was checked in the iPad simulator. Check sidebar selection, trailing Room info inspector (button + ⌘I), Slide Over / Split View collapse to a sheet, rotation, and Settings/Stickers in the detail column.
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, interactive Xcode/Instruments NFR-2 scroll hitch ratio + 300-room NFR-1 check + MetricKit hang/launch review (dev-account iPhone 16 baseline recorded in `TEST_STRATEGY.md` §7: 0.357 s responsive launch, 76.8–78.1 MB peak memory), and Beta 1 → Beta 2 → 1.0 release. (Voice, Share extension `V-SHARE-1`, Focus filter `D90`/`D104`, and Siri/Spotlight `D88` verified green on iPhone 16.)

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. **Autonomous loop (M17 → M18 → M19):** start M17 ship-readiness polish & hardening (land WIP `HaloUITests.swift` perf metric if ready, room-open smoothness & thumbnail caching, crash-safety/`try? await` sweep, Reduce Motion/Contrast, file-size splits, L10n string extraction), then proceed through M18 (everyday messaging completeness) and M19 (power-user organization, trust & ecosystem).
2. Founder deploys `infra/sygnal/` + APNs keys, requests KLIPY production access (`Q-KLIPY-PROD`), and uploads Beta 1 to internal TestFlight.
3. Founder runs physical-device checks in §5 📱 (room opening, composer panels, voice/location/poll/article sending, iPad split/inspector, widgets, Focus filter, Siri/Spotlight, Share extension, 7-day AC-U8 soak, NFR-1/NFR-2 perf).
4. Before Beta 2 / 1.0: publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md`, finalize Beta 2 brand artwork, and complete legal/export compliance.

## 7. Next Session Prompt
```text
/loop Read AGENTS.md, HANDOFF.md, docs/development/AUTONOMOUS_LOOP.md, and docs/ROADMAP.md.
Execute the expanded roadmap in a continuous Plan → Implement → Verify → Review → Land loop across M17 (Ship-readiness polish & hardening), M18 (Everyday messaging completeness), and M19 (Power-user organization, trust & ecosystem).

Start by inspecting any uncommitted WIP in ios/UITests/HaloUITests.swift on the current branch, then pick the first unchecked autonomous item in ROADMAP.md §"Remaining work" under M17 and proceed milestone by milestone until M17–M19 are complete.

Checks per iteration:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- scripts/contract-test.sh / scripts/contract-offline-test.sh when touching adapter, sync, timeline, or read-state code
- Simulator visual verification (Light, Dark, AX5) for UI changes
- Update HANDOFF.md and ROADMAP.md checkboxes in the last commit of every push (AGENTS.md §18).
```
