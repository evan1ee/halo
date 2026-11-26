# Halo — Session Handoff

Last updated: 2026-11-26 · Branch: `feat/m19-performance` (from `main` after #100) · PRs #1–#100 merged before it

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap:** M0–M16 are built and merged. Re-planned 2026-11-25 to a production release (D121): M17 measure → M18 security and reliability → M19 performance → M20 messaging → M21 experience → M22 beta and launch, with gates G-SCALE, G-PERF, G-SHIP ([docs/ROADMAP.md](docs/ROADMAP.md)). The audit behind it found 26 gaps (ROADMAP §2); Halo isn't a release candidate yet.
- **Milestones:** M0–M16 built, partly for M14–M15 (GA-24…GA-26). **M17 in progress:** M17-1, 2, 3, 6, 8 done; M17-4, M17-5 and M17-7 done except what needs a device or the founder (§5). **M19 started early (D125): M19-11 message search and M20-1 jump to any message are built and merged (PR #91; the iPhone checks are still open)**. **M18 started: M18-1 merged (PR #92); M18-2 to M18-5, M18-7 and M18-9 merged (#93–#98); M18-8 no silent failures merged (#99); M18-11 delivery under faults built, M18-13 sign out other sessions built (all merged, #100); M19-1 one image pipeline, M19-2 incremental timeline (part), M19-3 incremental room list, M19-4 room opening built, M19-5 media by file (part), M19-9 motion audit tool, first pass, D-MOT-2 fixed for the top three rooms**; M18-6 needs the founder; M18-10, M18-12 next. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`), physical iPhone 16 (`00008140-000222592ED0801C`, iOS 27.2.1).
- **Last checks:** this push changes only docs (measurements); `scripts/validate-docs.sh` and `scripts/check_handoff.py` passed. The code is unchanged since `6eb7b9f`, whose checks were: `HALO_SIM="iPhone Air" scripts/prepush.sh` passed; S01–S29 (`ServerReadStateScenarioTests/realServerScenarios`) passed; D95 `testRoomOpeningLandsAtNewestTenTimes` passed; `motion_audit.py room-open-close room-open-other`; `perf.py --accounts scale300` (NFR-11 p95 0.206–0.222 s vs 0.275 s; idle CPU §5). **Not run:** the full contract suite, `infra/test/run.sh`, an iPhone, VoiceOver.
- **CI:** PRs #1–#90 merged. New `scenarios.yml` (Synapse behind the fault proxy). Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **M19-9 / D-MOT-2 warm view models (2026-11-26):** `WarmTimelines` (FeatureTimeline) keeps a started `TimelineViewModel` for the top three rooms of the chat list; `AppRoot.makeRoomTimeline` hands it to the pushed room. Until `present()` (the screen appeared) it reports nothing: no receipt, no own message as read, no `m.marked_unread` clearing, no draft write or typing notice; then it lands at the newest row and reads the read position again. Freed when a room leaves the top, on sign-out, on a memory warning; a closed room is prepared again. Film: 0 empty frames on the first open after a launch and on a re-open (was 6 on the re-open). Details and numbers: `docs/testing/MOTION_AUDIT.md` "D-MOT-2 fix".
- **M19-9 rooms outside the top three (2026-11-26, measured, no code kept):** a probe in `start()` showed the serial reads take < 10 ms; the first open loses 313–385 ms before `start()` even runs, to SwiftUI building the room screen on the busy main actor. Starting the model as the screen is built didn't help (its task waits for the same main actor) and was dropped. Details: MOTION_AUDIT "Where a room outside the top three loses its time".
- **M19-9 follow-up (2026-11-26):** touch-down warming of a chat row was built, found to swallow the row's tap (and a list delays touch-began for quick taps anyway), and dropped; kept from it: models held back from the moment they are made, `start()` waits for a start under way, a late start ahead can't hide a shown screen (`WarmTimelinesTests`). New film scenario `room-open-other` (fifth chat), which asserts that the room opened.
- **Earlier on this branch (2026-11-26):** launch always shows the chat list; M19-9 motion audit tool and D-MOT-1 (`TimelineView.startsPlaced`); M19-5 media by file (part); M19-4 room opening (landing waits 16 + 32 ms); M19-3 incremental room list; M19-2 incremental timeline (part); M19-1 one image pipeline.
- **Merged before the branch:** M18-1…M18-5, M18-7…M18-9, M18-11, M18-13 (#92–#100); M19-11 message search with M20-1 (#91); M17 measure and prove, unread badge and background sync (D118), account data (D120) (#88). See `git log`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D125), [docs/adr/README.md](docs/adr/README.md).
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
- **M19-9 follow-up:** `FeatureTimeline/{TimelineViewModel (start awaits a start under way, wasPresented), WarmTimelines (install holds back)}`, `WarmTimelinesTests`, `ios/UITests/HaloUITests` (`room-open-other`), `scripts/motion_audit.py`, MOTION_AUDIT.
- **M19-9 D-MOT-2 (previous push):** `FeatureTimeline/{WarmTimelines (new), TimelineViewModel (startAhead, present, isPresented), TimelineViewModel+Mapping, TimelineView (onAppear → present)}`, `Tests/FeatureTimelineTests/WarmTimelinesTests` (new); `App/{AppRoot (warmTimelines, memory warning), HaloApp (TimelineScreen, router path → screensChanged), Composition/ChatsAssembly (makeRoomTimeline), Composition/SessionAssembly (dropAll)}`; docs: MOTION_AUDIT, TIMELINE §4, READ_RECEIPTS §1, ROADMAP M19-9.
- Earlier pushes: see `git log`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Not done, for future action (from the M18 and M19 work; remove a line when done)**
- **M19-9:** rooms outside the top three still show the empty message area on open (`room-open-other`: 6–9 frames first open, 2–3 re-open): the cost is the first build of the room screen (≈ 300–385 ms main thread), not the reads (< 10 ms); next profile it with Instruments' SwiftUI template (or on the iPhone 📱), or start more rooms ahead; touch-down and starting the model in `TimelineScreen.init` were tried and dropped (MOTION_AUDIT); idle CPU per minute on `scale300` was 3.01 s on the commit before the warm models and 3.64 / 3.93 s after (two runs; the simulator varies up to 28 %, the time is the message-search FTS5 indexer, the stored 0.61 s baseline predates message search): measure on the iPhone 📱 whether the three live timelines cost anything at idle; the rest of D-MOT-1 for rooms over 40 rows or with photos; make the film window exact (the re-open fell after it and was cut by hand), then read send / reaction / scroll up / room close / appearance strips; scenarios for edit, reconnect, history prepend; fix `send` (software keyboard), `appearance`, `launch`; UI tests for what can be measured; run on the iPhone 📱. Details: `docs/testing/MOTION_AUDIT.md` "To do".
- **M19-5:** own thumbnails downloaded again after a restart, gallery pages, progress and cancel while a file opens, memory of a 100 MB video (📱), an encrypted room's file, the image viewer still loads full photos with `content`.
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
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).

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
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (Beta/Release push gateway deploy):** deploy `infra/sygnal/` (D112) with APNs keys, verify V-PUSH-5 live, and upload Beta 1 to TestFlight.
- 👤 **UX/ship external items (D84, D115):** publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md` with founder domain/contact, final Beta 2 brand artwork (`Q-BRAND`), legal review (D38), export compliance (V-LEGAL), and App Store Connect privacy nutrition labels.
- 📱 **Drag and drop (iPad):** drop a photo, a PDF and a link from Photos/Files/Safari into an open chat, and drag text, a photo, and a file out of a chat (also Split View with another app); a > 50 MiB file shows the size error.
- 📱 **Keyboard shortcuts (iPad/hardware keyboard):** ⌘N, ⌘,, ⌘F, ⌘1–⌘6 work and ⌘F focuses the search field.
- 📱 **Widgets in the background (D118):** icon verified live; the widget refreshed on open, but on the founder's phone iOS ignored every background reload (extension and app) on 2026-11-24, most likely a spent daily reload budget. Re-check with Settings → Developer → WidgetKit Developer Mode, or after a day. iOS's own scheduling of the app refresh was only simulated (debugger).
- 📱 **iPad on a device / dev homeserver (D91):** only the signed-out screen was checked in the iPad simulator. Check sidebar selection, trailing Room info inspector (button + ⌘I), Slide Over / Split View collapse to a sheet, rotation, and Settings/Stickers in the detail column.
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, interactive Xcode/Instruments NFR-2 scroll hitch ratio + 300-room NFR-1 check + MetricKit hang/launch review (dev-account iPhone 16 baseline recorded in `TEST_STRATEGY.md` §7: 0.357 s responsive launch, 76.8–78.1 MB peak memory), and Beta 1 → Beta 2 → 1.0 release. (Voice, Share extension `V-SHARE-1`, Focus filter `D90`/`D104`, and Siri/Spotlight `D88` verified green on iPhone 16.)

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §3.
1. Open M18 items: M18-10 (device matrix 📱), M18-12 (security review 👤), M18-6 (OIDC end to end 👤); then Q-VERIFY before M18 ends.
2. M19 on `feat/m19-performance` (no PR until the milestone is done, D75): M19-1…M19-5 built or part built (see "Not done" in §5); next the rest of the M19-9 audit (rooms outside the top three, the other transitions; §5), M19-7 (sync and energy), M19-6/8/10 need the iPhone. M20-11 (search inside a room) only needs its interface now (`SearchQuery.room`).
3. Founder: the device and hand checks of §5; long lead times: push gateway (M22-1), legal (M22-4), KLIPY production key, filtering entitlement, artwork.

## 7. Next Session Prompt
```text
/loop Read AGENTS.md, HANDOFF.md, docs/development/AUTONOMOUS_LOOP.md and docs/ROADMAP.md (§1–§3, §7).
Work the ROADMAP §3 queue from M18-1: Plan → Implement → Verify → Review → Land, R tasks first.

A task is done only when its "Done when" holds by a test that failed before, its GA row is removed, its spec no longer says
"not built", and the rules of ROADMAP §1 hold. G-SCALE is accepted with conditions (D125); G-PERF and
G-SHIP are the founder's. 1.0 scope is fixed (D122). Open decision: Q-VERIFY.

Checks per iteration:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- scripts/contract-test.sh (adapter, sync, timeline, read state); it fails if a run leaves rooms or devices
- Simulator check in light, dark and AX5 for UI changes
- infra/test/run.sh faults|interop when sending, sync or timeline mapping changes; infra/test/run.sh search for message search
- Never scale-test on stickertester or contractpeer; use the M17-3 accounts
- Update HANDOFF.md, ROADMAP.md and the owning spec in the last commit of every push (AGENTS.md §18).
```
