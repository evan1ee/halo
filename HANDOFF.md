# Halo — Session Handoff

Last updated: 2026-11-28 · Branch: `feat/m21-state-matrix` (PRs #1–#114 merged; M21-1 ready for PR)

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap:** M0–M16 are built and merged. Re-planned 2026-11-25 to a production release (D121): M17 measure → M18 security and reliability → M19 performance → M20 messaging → M21 experience → M22 beta and launch, with gates G-SCALE, G-PERF, G-SHIP ([docs/ROADMAP.md](docs/ROADMAP.md)). The audit behind it found 26 gaps (ROADMAP §2); Halo isn't a release candidate yet.
- **Milestones:** M0–M16 built, partly for M14–M15 (GA-24…GA-26). **M17 in progress:** M17-1, 2, 3, 6, 8 done; M17-4, M17-5 and M17-7 done except what needs a device or the founder (§5). **M18:** all non-founder/non-device R/C tasks merged (#92–#100); M18-6/M18-12 need the founder, M18-10 needs a device. **M19:** merged (#101) with all non-device R tasks built (M19-1…M19-5, M19-7, M19-9, M19-11); M19-6/8/10 need a physical iPhone 📱. **M20:** all non-founder/non-upstream R tasks done and merged — M20-1 (#91), M20-2 (#102), M20-3 (#103, GA-18 removed), M20-4 (#104, GA-19 removed), M20-5 (#105, GA-20 removed), M20-6 (#106), M20-8 (#107, GA-23 removed), M20-9 (#108), M20-10 (#109, GA-30 removed), M20-11 (#111), M20-12 (#112), M20-13 (#114); remaining M20 R tasks are externally gated: M20-7 report/block (`Q-REPORT` 👤) and M20-19 unknown msgtypes (`GA-31`, verified upstream `matrix-rust-sdk` 26.11.17 gap 📤; Halo mapper ready). **M21 in progress:** M21-1 State matrix built (`feat/m21-state-matrix`, closes UX-19 and GA-25 part 1). **Architecture audit (2026-11-27/28):** PR #110 (P1/F-02), S-6, and PR #113 (P2 batch: F-08, P-1/P-2, P-4/P-5) merged. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`), physical iPhone 16 (`00008140-000222592ED0801C`), physical iPhone 17e (`00008150-001149800E7B401C`).
- **Last checks (M21-1 State matrix, 2026-11-28):** `HALO_SIM="iPhone Air" scripts/prepush.sh` passed (nothing skipped; handoff, docs, boundaries + 6/6 boundary tests, design tokens, HaloCore, HaloApple incl. `StateComponentsTests` + `StickerLibraryViewModelTests` + `UserProfileViewModelTests`, `Halo-Debug` build, full `HaloUITests`, gitleaks, 0 SwiftLint violations in 335 files); Light, Dark, and AX5 snapshots of `LoadingState`, `ErrorState`, and `HaloBanner` visually verified.
- **Earlier checks (M20-19 + full M20 interop, PR #114 M20-13, 2026-11-28):** `HALO_SIM="iPhone Air" infra/test/run.sh interop` passed all 7 live Synapse interop tests (75.54 s, 1 verified upstream known issue `GA-31`); all GitHub CI checks passed on #114; `StorageContractTests` (2.38 s) passed on live Synapse.
- **CI:** PRs #1–#114 merged. `scenarios.yml` (Synapse behind the fault proxy); Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **M21-1 State matrix (2026-11-28, `feat/m21-state-matrix`):** Extended `HaloDesignSystem` `LoadingState` with `.rows`, `.grid`, and `.detail` skeletons, added custom icon + AX5 vertical stacking to `ErrorState` and `HaloBanner`, and added retryable failure UI to `PagedPhotoViewer`. Replaced bare list/grid/detail spinners and raw error/empty views across `GlobalMediaGalleryView`, `RoomDetailsView`, `RoomMediaGalleryView`, `UserProfileView`, `BotActivityView`, `NewChatView`, `MessageSearchResultsSection`, `TimelineView` (`DelayedLoadingState` preserving D126 0-flash + inline pagination `ErrorState`), `PinnedMessagesSheet`, `EditHistoryView`, `StickerPanelView`, `KlipyPanelView`, `StickerLibraryView` (+ `StickerLibraryViewModel.loadFailed`), `AddToStickerPackSheet`, `DevicesSettingsView`, `StickerPackSettingsView`, and `RecoveryView`. Recorded the S1–S15 state matrix in `docs/design/SCREEN_SPECIFICATIONS.md`, closed `UX-19`, and verified with Light/Dark/AX5 snapshots and unit regression tests.
- **M20-19 Unknown message types investigation & mapper prep (2026-11-28):** Updated `TimelineMapper` to map `MessageType.other(_, body)` to the sender's fallback text when non-empty (verified with `UTDReasonTests.unknownMessageFallback`). Verified empirically on live Synapse against `matrix-rust-sdk` 26.11.17 that `room.timeline()`, `TimelineFilter.all`, and `TimelineFilter.eventFilter(.exclude([]))` all omit unknown `msgtype` events upstream before the FFI diff listener — confirmed M20-19 / `GA-31` requires an upstream SDK change (📤) and re-ran the full `InteropTests` suite.
- **M20-13 Storage (2026-11-28, merged #114):** Added `MediaCacheRetention` (D55: 1 GB / 30 days default), `StoreSizeBreakdown`, `MediaCacheClearResult`, and `StoragePort` (`HaloDomain`), `StorageCoordinator` + `PreferencesStore.mediaCacheRetention` (`HaloApplication`), `UserDefaultsPreferencesStore` persistence (`HaloPlatform`), `ImagePipeline.clearCache()` (`HaloDesignSystem`), `MatrixStoragePort` + `MatrixSessionPort` using SDK `getStoreSizes()` and `setMediaRetentionPolicy` to clear only cached media while preserving encryption keys, `stateStore` send queue, and `halo.sqlite` (AC-SET-3), and `StorageSettingsSection` + `StorageSettingsViewModel` (`FeatureSettings`) wired into `AppRoot` / `SettingsAssembly`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D128), [docs/adr/README.md](docs/adr/README.md).
- **D127 (ADR-0025):** the composer stays in `FeatureTimeline`; `FeatureComposer` is retired and removed in a later code change.
- **D128:** each upstream `TaskHandle` is cancelled by a `defer` in its scope or by its stream's `onTermination` (no `SubscriptionToken` type).
- **D126:** a room's timeline starts when it is chosen (tap → start → push with rows, ≤ 150 ms wait); no view models ahead for the top rooms.
- **D121:** roadmap re-planned; R/C/P classes; G-SCALE before M19; the sync path is D125.
- **D125:** G-SCALE accepted on simulator numbers, classic sync stays, M19 may start; iPhone, real account and M19-11 still to show before G-PERF.
- **D123 (ADR-0024):** message search over Halo's own index: encrypted rooms, full history (founder; resolves Q-SEARCH-INDEX). **D124:** its file is unreadable while locked; an encrypted holding file takes overnight history.
- **D122:** 1.0 ships the smaller scope (founder; resolves Q-SCOPE).
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
- **Design system (`HaloDesignSystem`):** `Components/{LoadingState.swift, ErrorState.swift, Banner.swift}`, `Media/PagedPhotoViewer.swift`.
- **Features:** `FeatureMedia/GlobalMediaGalleryView.swift`, `FeatureRoomDetails/{RoomDetailsView.swift, RoomMediaGalleryView.swift}`, `FeatureProfile/UserProfileView.swift`, `FeatureBotActivity/BotActivityView.swift`, `FeatureRoomList/NewChatView.swift`, `FeatureSearch/MessageSearchResultsSection.swift`, `FeatureTimeline/{TimelineView.swift, PinnedMessagesSheet.swift, TimelineSecondarySheets.swift}`, `FeatureStickers/{StickerPanelView.swift, KlipyPanelView.swift, StickerLibraryView.swift, StickerLibraryViewModel.swift, AddToStickerPackSheet.swift}`, `FeatureSettings/{DevicesSettings.swift, StickerPackSettings.swift}`, `FeatureOnboarding/RecoveryView.swift`.
- **Tests:** `HaloDesignSystemTests/StateComponentsTests.swift`, `FeatureStickersTests/StickerLibraryViewModelTests.swift`, `FeatureProfileTests/UserProfileViewModelTests.swift`.
- **Docs:** `docs/design/{SCREEN_SPECIFICATIONS.md, UX_AUDIT.md}`, `docs/ROADMAP.md`, `HANDOFF.md`.
- Earlier pushes: see `git log`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Not done, for future action (from the M18–M20 work; remove a line when done)**
- **Architecture audit, still open ([ARCHITECTURE_AUDIT.md](docs/ARCHITECTURE_AUDIT.md) §6):** remaining P2 items only (S-3 `TimelineCoordinator` pass-throughs, F-03 `MatrixSessionPort` split, F-06 `sessionUpdates` actor isolation, F-07 platform side effects behind ports, S-5 image cache unification, #12 CI scale gate); all P1 items, S-6, F-08, P-1/P-2, and P-4/P-5 are done.
- **`HaloUITests.testPastedImageJoinsPendingPhotos` flake (2026-11-27):** failed once in a full `prepush`, passed 2 of 2 alone right after and in a full-suite rerun; the change on the branch doesn't touch pasting. Watch it.
- **M20-5:** live hardware photo/video capture & iOS permission prompt on a physical iPhone 📱; `NSCameraUsageDescription`, in-context `CameraAccessPolicy`/`CameraPermissionController`, denied/restricted/unavailable UI with Settings link, lossless video GPS stripping (`VideoPreparer`) & photo GPS stripping (`ImagePreparer`), and Light/Dark/AX5 snapshots are built and verified.
- **M20-3:** 100 MB video memory measurement, portrait/landscape full-screen rotation feel, and Save to Photos permission flow on a physical iPhone 📱; inline posters, disk-streamed `AVPlayerViewController`, captions on send, poster thumbnails, Save/Share, Light/Dark/AX5, and interop tests are built and verified.
- **M20-2:** live phone-call interruption, Bluetooth headphone disconnect, and VoiceOver check on a physical iPhone 📱; inline player, Element Ogg Opus interop, MSC3245/MSC1767 send & receive, Light/Dark/AX5, and unit tests are built and verified.
- **M19-9:** all 12 transitions filmed with exact post-end calibration and visually inspected, D-MOT-1/2/3 fixed, `--assert` blank-frame check and `testRoomOpenShowsRowsAtNewestWithoutSpinner` added; remaining: physical iPhone room-open check and a re-opened room with photos 📱, ~200 ms once-per-launch first-room SwiftUI/runtime setup, and ~1-viewport SwiftUI `List` height-estimation shift on history prepend (`docs/testing/MOTION_AUDIT.md`).
- **M19-7:** 1 h idle foreground energy measurement (NFR-15) and `scale1000` device timing on a physical iPhone (📱); `SyncEnergyPolicy`, empty-poll FFI/read-state skip, Low Power / thermal / offline adaptation, and persisted `EventTimeCache` (GA-28) are built and verified.
- **M19-5:** memory measurement of a 100 MB video on a physical iPhone (📱); all file streaming, viewer/export disk decoding, progress + cancel, encrypted files, zero-request cache & own-thumbnail restart, and room/global gallery paging are built and verified on the simulator + real Synapse.
- **M19-4:** the same on the iPhone (the UI-test runner timed out enabling automation: phone locked or UI Automation off); no change to the other NFR rows.
- **M19-3:** the adapter over a real 1,000-room server (`ScaleMeasurements` consumes the new updates but wasn't run), device timings; the coordinator still recomputes summaries and read inputs from the whole list per change.
- **M19-2:** grouping, state-run collapsing, profile and sender-name scans and `readTracker.update` still walk every item; nothing runs off the main actor; no device timing.
- **M19-1:** NFR-12/13 on a device, first-frame paint (M19-9), animated stickers keep their own decoder.
- **M18-13:** the OIDC account page (M18-6), VoiceOver, an iPhone look.
- **M18-11:** a sticker is sent with `send_raw`, outside the queue (no retry; a lost answer shows a failure though the server has it; needs the SDK change R-18/R-21); a real token refresh (Synapse with short token lifetimes, M18-6); an upload slower than 15 s (the new request timeout may cut it; check with a large photo on a slow network). Run: `infra/test/run.sh faults`.
- **M18-8:** `ActionGuard` on the other screens (they keep their own flags) and a double-tap test per action; `try?` without `await` is outside the rule. 
- **M18-7:** V-PUSH-4 on an iPhone (action from a terminated app), and G-NSE needs a re-run because the NSE changed.
- **M18-9:** a UI test with a link in a message, a device look 📱; no join preview with the room's name.
- **M18-5:** the screens on an iPhone, a launch while locked 📱. The SDK text match can miss other damage; those stay "Try again" with the old message.
- **M18-4:** restore to a new device, Spotlight and pusher on an iPhone.
- **M18-3:** the OIDC approval (M18-6), VoiceOver, an iPhone look.
- **M18-2:** a real server never refuses under the default recipient strategy (D117), so no end-to-end test; no "Review devices" button (the text says what to do); VoiceOver and iPhone look.
- **M18-1:** verifying a contact (no flow exists), a timeline row (the banner is the notice), VoiceOver and iPhone checks.

**Waiting for the founder before work can pass a point**
- 👤 **Q-VERIFY** before M18 ends · **Q-REPORT**, **Q-SIGNUP**, **Q-REVIEW** later.

**Engineering (not blocking)** — the gaps are in ROADMAP §2, not repeated here.
- **`SessionCoordinatorTests` flake:** "start returns only when a revoked session has been forgotten…" failed once in a full `prepush` (expected `.signedOut(.unauthorized)` after 0.07 s) and passed 6 of 6 alone and on rerun; HaloCore was unchanged on that branch. Look at the timing if it comes back.
- **Message search, known limits:** the per-room listeners cost +20 MB at 1,000 rooms (at the limit); a live poll is found at once only in the 200 most recent rooms; taking rows out is slow on purpose (`secure-delete`), so leaving a huge room takes a while in the background; a focused timeline's events stay in memory for the app's life (about 0.5 KB each, F-FFI-26).
- **`timeline` contract flake:** `verifyInteractions` timed out (90 s) in the first 3 of 12 completed full runs on the branch, then in none (one more run was stopped at 290 s, unfinished); 0 of 2 on `main` the same hour, 0 of 4 alone. The same test also timed out on earlier branches. The step is unknown; the tests now name it in the failure ("timed out …: never saw …").
- **Scale server:** `halo-scale` (about 1 GB) is left stopped or running on the dev Mac for M19; `infra/dev/scale-fixtures.py down` / `remove --yes`. Simulator `Halo Perf` belongs to `scripts/perf.py`.
- **Accessibility audit (watch):** `testLaunchRootScreenPassesAccessibilityAudit` failed at times until 2026-11-24 (also on `main`), "Potentially inaccessible text" without an element; 12 of 12 runs passed on 2026-11-25 with the cleaned-up account. Cause unknown, no exemption added.
- **Dev APNs stall (2026-11-24, 15:05–15:19 UTC):** APNs accepted pushes the iPhone never acted on (alerts and silent ones), then delivery resumed without a change; a later silent push also had no effect within 12 s (iOS throttles them; opening healed it). Cause unknown.
- **Account data (D120 limit):** two devices writing the same type in the same moment can still lose one change (Matrix has no conditional write).
- **`Halo (iPhone)` sessions on the dev accounts:** stickertester has 10, contractpeer 4 (the app's own sign-ins, some from reinstalls); which are live can't be told from the server, so nothing touches them: sign old ones out in Settings → Sessions. About 120 throwaway users from before 2026-11-25 (`e2ee…`, `scen_…`, `rules_…`) remain.
- **S29 server flake (was 1 of 8 runs):** Synapse rotated its push counts 90 ms before the receipt arrived and kept reporting the old count (its database was right). Not a Halo rule; the scenario now runs once more in a new room, only when the server's own sync still reports the wrong count.
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed).

**Needs the founder (`👤`) or physical device (`📱`)**
- 📱 **Message search on the iPhone:** lock the phone while it reads (index unreadable, search and reading go on after unlock), the processing task on the charger (Xcode: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"one.mbm.halo.search"]`), file protection `complete`, energy, first sync of `scale1000`, no `0xdead10cc` when the app goes to the background while it reads (the second SDK client uses the stores in the App Group); VoiceOver of the results.
- 📱 **M17-4/M17-5 on the iPhone 16:** `scripts/perf.py --device 00008140-000222592ED0801C --save-baseline` (signed-in account), one hour idle for energy (NFR-15), first sync of `scale1000` with and without the search index (needs the phone signed in to the scale server: `HALO_SCALE_BIND=0.0.0.0`).
- 👤 **M17-4:** first sync and catch-up of one real public-server account. 👤 **M17-7:** the Element Web / Element X checklist, about an hour.
- 📱 **M17-1/M17-2:** the NSE interval and a MetricKit payload on a device (Xcode → Debug → Simulate MetricKit Payloads, then Settings → Diagnostics → Export).
- 👤 **Q-KLIPY-PROD:** the KLIPY key is a testing key (100 requests/hour); request production access in KLIPY's Partner Panel before Beta 1.
- 📱 **UI tests on devices:** the iPhone 16 (`00008140-000222592ED0801C`, signed in as contractpeer on the LAN dev server) runs `HaloUITests` (composer, empty room, launch). The iPhone 17e still exited with code 74.
- 📱 **Location, polls and articles:** pinned location, poll, Markdown article, and KLIPY GIF live sends verified in Halo on iPhone 16 (`testLiveSendsLocationPollArticleAndKlipy`); still open: current-location send + Element interoperability check.
- 📱 **Voice messages on a device:** record, cancel, send, and playback verified green on iPhone 16; still open: Element interoperability check.
- 📱 **Composer panels on a device:** keyboard ↔ panel swap and KLIPY GIF inline send/play verified on iPhone 16; still open: iPad floating/hardware keyboard, composer following keyboard from idle, and KLIPY GIF link interoperability in Element (AC-CP3).
- 📱 **Opening rooms on the device (D95):** S10 10× room-opening check verified green on iPhone 16 (`testRoomOpeningLandsAtNewestTenTimes`, 10/10 at newest message, no spinner); still open: notification-tap / Spotlight entry and iPad split view.
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-18, R-21 & M20-19/GA-31 (upstream SDK gaps):** `SyncSettingsV2` filter, queued `sendRaw`/`sendSticker`, and unknown `m.room.message` `msgtype` delivery in `matrix-sdk-ui` timelines (verified 2026-11-28 on pinned 26.11.17: omitted even under `TimelineFilter.all` and `.eventFilter(.exclude([]))`; Halo's `TimelineMapper` is ready for `MessageType.other`) need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (Beta/Release push gateway deploy):** deploy `infra/sygnal/` (D112) with APNs keys, verify V-PUSH-5 live, and upload Beta 1 to TestFlight.
- 👤 **UX/ship external items (D84, D115):** publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md` with founder domain/contact, final Beta 2 brand artwork (`Q-BRAND`), legal review (D38), export compliance (V-LEGAL), and App Store Connect privacy nutrition labels.
- 📱 **Drag and drop (iPad):** drop a photo, a PDF and a link from Photos/Files/Safari into an open chat, and drag text, a photo, and a file out of a chat (also Split View with another app); a > 50 MiB file shows the size error.
- 📱 **Keyboard shortcuts (iPad/hardware keyboard):** ⌘N, ⌘,, ⌘F, ⌘1–⌘6 work and ⌘F focuses the search field.
- 📱 **Widgets in the background (D118):** icon verified live; the widget refreshed on open, but on the founder's phone iOS ignored every background reload (extension and app) on 2026-11-24, most likely a spent daily reload budget. Re-check with Settings → Developer → WidgetKit Developer Mode, or after a day. iOS's own scheduling of the app refresh was only simulated (debugger).
- 📱 **iPad on a device / dev homeserver (D91):** only the signed-out screen was checked in the iPad simulator. Check sidebar selection, trailing Room info inspector (button + ⌘I), Slide Over / Split View collapse to a sheet, rotation, and Settings/Stickers in the detail column.
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, interactive Xcode/Instruments NFR-2 scroll hitch ratio + 300-room NFR-1 check + MetricKit hang/launch review (dev-account iPhone 16 baseline recorded in `TEST_STRATEGY.md` §7: 0.357 s responsive launch, 76.8–78.1 MB peak memory), and Beta 1 → Beta 2 → 1.0 release. (Voice, Share extension `V-SHARE-1`, Focus filter `D90`/`D104`, and Siri/Spotlight `D88` verified green on iPhone 16.)

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §3.
1. Continue **M21** R tasks in order: **M21-3 Motion & system settings** (removes GA-25 & UX-20) → **M21-4 Visual regression tests** → **M21-6 Localisation** (removes GA-24) → **M21-7 Copy** → **M21-9 First run without an account**.
2. Return to **M20-7 Report and block** (removes GA-22) once founder decides `Q-REPORT`, and **M20-19 Unknown message types** (removes GA-31) once upstream `matrix-rust-sdk` delivers custom `msgtype` events in timelines (📤).
3. Remaining optional P2 audit items (S-3, F-03, F-06, F-07, S-5) and open M18/M19 device/founder items: M18-10 (📱), M18-12 (👤), M18-6 (👤), Q-VERIFY; M19-6/8/10 (📱).
4. Founder: the device and hand checks of §5; long lead times: push gateway (M22-1), legal (M22-4), KLIPY production key, filtering entitlement, artwork.

## 7. Next Session Prompt
```text
/loop Read AGENTS.md, HANDOFF.md, docs/development/AUTONOMOUS_LOOP.md and docs/ROADMAP.md (§1–§3, §7).

M21-1 State matrix is built (UX-19 closed). Continue the ROADMAP §3 M21 queue starting at M21-3 (Motion and system
settings: all animations through HaloMotion, Reduce Motion/Reduce Transparency/Increase Contrast/Bold Text, lint for
raw withAnimation, removes GA-25 and UX-20), then M21-4 (Visual regression tests in prepush.sh), M21-6 (Localisation,
removes GA-24), M21-7 (Copy: single HaloErrorCopy source), and M21-9 (First run without an account).

Rules learned in the audit (keep them true):
- Badge counts and totals only through BadgeCalculator (AGENTS §4.2); no `+=` on counts anywhere else.
- No class/actor in App/, NotificationService/, ShareExtension/, WidgetExtension/ except AppRoot, OS entry points
  and `…Box` holders (check_boundaries.py); new behaviour goes into HaloApplication or a feature, with unit tests.
- Preferences only through the shared PreferencesStore; the composer lives in FeatureTimeline (D127).
- A bug fix needs a test that failed before.

A task is done only when its "Done when" holds by a test that failed before, its GA row is removed, its spec no longer
says "not built", and the rules of ROADMAP §1 hold. G-SCALE is accepted with conditions (D125); G-PERF and G-SHIP are
the founder's. 1.0 scope is fixed (D122). Open decisions: Q-VERIFY, Q-REPORT (for M20-7).

Checks per iteration:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- scripts/contract-test.sh (touched contracts); it fails if a run leaves rooms or devices
- infra/test/run.sh faults|interop|search when sending, sync, timeline mapping or search changes
- Simulator check in light, dark and AX5 for UI changes
- Never scale-test on stickertester or contractpeer; use the M17-3 accounts
- Update HANDOFF.md, ROADMAP.md and the owning spec in the last commit of every push (AGENTS.md §18).
```
