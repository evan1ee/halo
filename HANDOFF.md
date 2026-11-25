# Halo — Session Handoff

Last updated: 2026-11-25 · Branch: `main` (this push through `feat/m17-measure`) · PRs #1–#89 merged before it

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap:** M0–M16 are built and merged. Re-planned 2026-11-25 to a production release (D121): M17 measure → M18 security and reliability → M19 performance → M20 messaging → M21 experience → M22 beta and launch, with gates G-SCALE, G-PERF, G-SHIP ([docs/ROADMAP.md](docs/ROADMAP.md)). The audit behind it found 26 gaps (ROADMAP §2); Halo isn't a release candidate yet.
- **Milestones:** M0–M16 built, partly for M14–M15 (GA-24…GA-26). **M17 in progress:** M17-1, 2, 3, 6, 8 done; M17-4, M17-5 and M17-7 done except what needs a device or the founder (§5). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`), physical iPhone 16 (`00008140-000222592ED0801C`, iOS 27.2.1).
- **Last checks:** `prepush.sh` passed on the pushed commit (package tests, app build, UI tests, docs, boundaries, gitleaks, swiftlint); `infra/test/run.sh scenarios`, `faults` (9 cases) and `interop` (2 known issues) green; fault cases red for a client broken on purpose; full contract suite 38 tests green, but see the `timeline` flake in §5. Simulator and dev Mac only; nothing was run on an iPhone.
- **CI:** PRs #1–#89 merged. New `scenarios.yml` (Synapse behind the fault proxy). Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **M17 measure and prove (2026-11-25, `feat/m17-measure`):**
  - **M17-1** `HaloSignpost` (cold start, room open, sync, image decode, NSE, hangs) read by XCTest in the running app. **M17-2** MetricKit payloads on the device, redacted and bounded, in the diagnostics export.
  - **M17-3** `infra/dev/scale-fixtures.py`: a server of its own (`halo-scale`, port 8108) with 300 and 1,000 rooms, a 10,000-member and a 20,000-event room. **M17-6** `infra/test` with the fault proxy, F01–F06, `FaultTests`, `scenarios.yml`.
  - **M17-4** measured (TEST_STRATEGY §7): classic sync is fine at 1,000 rooms (11.8 s first sync, 0.9 s catch-up) **without the SDK's message search index**; with it 32–43 s and 13–19 s, 25 s CPU per idle minute, up to 925 threads. Q-SEARCH-INDEX → D123 (below).
  - **M17-5** `scripts/perf.py` + `HaloPerformanceTests` with `docs/testing/perf-baseline.json`. **M17-7** `InteropTests` (wire level) and the signed checklist (INTEGRATION_TESTS §4).
  - Also fixed: `SessionCoordinator.start()` could return while a revoked session was still being deleted (state "restoring"); found by a flaking unit test, regression test added.
  - Found: GA-27 (search index), GA-28 (one request per unread room per launch), GA-29 (39 s to recover from a half-open connection), GA-30 (mention's plain text), GA-31 (unknown types hidden).
- **M17-8 search spike (2026-11-25): passed on the simulator**, after two design changes: live lane on the SDK's per-room listeners, history in an SDK client of its own (the app's client never frees what is read, F-FFI-26). Encrypted history: 400 of 400 messages after recovery. Unread suite green with the SDK index off. Numbers in TEST_STRATEGY §7; `scripts/scale-measure.py --search`, `infra/test/run.sh search`. Production code: only the measurement switch `backPaginates`. Not measured: an iPhone, energy.
- **Message search decided (D123, ADR-0024, 2026-11-25, documents only, nothing built):** Halo's own FTS5 index, **encrypted rooms searchable**, full history, on the device only; spec `docs/features/MESSAGE_SEARCH.md` (AC-SRCH-1…9). Checked in the SDK source: the history sweep needs automatic back-pagination, the SDK indexes in memory even without a folder, keys come from the backup after a failed decryption (F-FFI-25). New M17-8 (spike), larger M19-11, M20-1 taken with it, GA-32 (bugs in today's search), V-SEARCH-2/3; index protection D124.
- **Production roadmap (D121, 2026-11-25, `docs/production-roadmap`):** audited code against every product, design, security, testing and release document at `155f745`; rewrote ROADMAP (gap table, R/C/P tasks with "Done when", gates, release plan), added AC-REL/AC-SEC/AC-MOT and NFR-11–15, V-SCALE-1, V-OIDC-1, V-INTEROP-1, Q-SCOPE, Q-SYNC-SCALE, Q-REPORT, Q-SIGNUP, Q-VERIFY, Q-REVIEW; corrected specs that promised unbuilt behaviour or described sliding sync.
- **Unread badge, widgets and background sync (D118, 2026-11-24, PR #88):**
  - Root causes: gateway down and Halo's pushkin never able to send (asyncio awaited on Twisted); dev ran the stock pushkin; background launches did nothing (handlers set in a view) and reported done before the badge was written; pre-sync evaluations overwrote what the NSE had counted; unordered badge writes; the NSE counted late pushes twice and raced itself; a sticky foreground flag; no refresh fallback; a widget reload on every open/close spent iOS's budget.
  - Verified on iPhone 16 via SpringBoard's icon value: pushes 8→10 suspended, 10→11 terminated; read elsewhere 11→0 in ~5 s suspended and from a cold background launch; 10 open/close cycles unchanged. A Focus with "Hide Notification Badges" hid the icon badge on the founder's phone (value was right throughout).
- **S11 offline read (D119, 2026-11-24, PR #88):** the own-latest case of `SDK_UNREAD_AFTER_READ` discarded a read that couldn't be sent when the SDK's latest event still was the user's own join. Real-server scenarios 8×: the ordering came up in 3 runs, S11 passed in all 8; one run failed later at S29 (see §5). Also fixed PR CI: a test closure Swift 6.2 on Linux rejects, and a gitleaks false positive.
- **`readMarkers` and other contract tests (2026-11-25, PR #88):** they waited for exactly `HALO_DEV_ROOMS` (106) rooms while the account was in 268, so they timed out before testing anything. They now wait for the room they need (`roomList` asks the server); the setting is gone. Rooms piled up because `defer { Task {…} }` cleanup never ran before the process ended: replaced by an awaited cleanup. Full contract run: 33 passed, 2 skipped, `stickers` failed on an extra sticker in the fixture pack (test fixed; passes after the account data below was restored).
- **Account data no longer overwritten (D120, 2026-11-25, PR #88):** sticker-pack lists, personal pins, the media-preview setting and the bot allowlist are changed from the server's copy (`ServerAccountData`), bot edits as a difference (`BotListEditor`), Saved Messages asks the server before making a room, and ignore/unignore write the server's list; creating a pack right after sign-in had replaced the account's list (`createPack` in a full contract run did it to stickertester; restored). `createPack`, `botAllowlist`, `savedRoom` and `ignoreKeepsOthers` failed before and pass now; the full contract suite is green with the accounts' data unchanged. Two tests assumed fixed sizes and were corrected: the timeline contract paged at most 200 events back (the room grew past it) and `testSentPhotoStaysVisibleAndShowsDeliveryState` counted images on screen (checked with a mutation run). It and `unavailablePack` put the shared account's lists back whatever happens.
- **Leftover test rooms and devices (2026-11-25, PR #88):** removed with the founder's OK: stickertester 269 → 9 rooms, contractpeer 320 → 6, 170 test devices, and 28 sticker-pack list entries of those or long-left rooms; backup in `~/.config/halo-dev/synapse-before-leftovers-2026-11-25.dump`. Tests now undo everything through the `.cleansUp` trait, also after a failure, and `contract-test.sh` fails a run that left something (`infra/dev/leftovers.py`, replaces `prune-sessions.py`; failed on the old tests, passes now). `createPack` only caught D120 on a large account; it now starts sync after creating the pack (mutation run).
- **Test harness (2026-11-25, PR #88):** the two keyboard UI tests no longer skip on the simulator (`prepush.sh` turns off the software keyboard's hiding; both pass), S29 survives the Synapse flake above (a real mismatch still fails, checked by mutation), and `create-fixtures.py --new-e2ee` / `smoke.sh` deactivate their throwaway user.
- **Room info as pushed full-bleed navigation page (2026-11-24, `main`):**
  - Replaced Room info `.sheet` presentation (timeline avatar button and room-list context menu) with `ChatsRoute.roomInfo(RoomID)`, `ChatsRouter.openRoomInfo(_:)`, `ChatsRouter.removeRoom(_:)`, and `RoomInfoPresentation.page` (keeping `.inspector` on regular-width iPad).
  - Removed the nested `NavigationStack` from `RoomDetailsView` and matched the conversation page's transparent, title-free header with full-bleed edge-to-edge scrolling (`.scrollEdgeEffectHidden(true, for: .top)`); verified with `HaloUITests.testRoomInfoOpensAsPushedPage` on physical iPhone 16.
- **Scroll-safe timeline long-press & image/map tap style + iPhone 16 verification (2026-11-24, PR #87):**
  - Removed SwiftUI `.simultaneousGesture(LongPressGesture)` + touch-down `.scaleEffect(0.96)` (which flashed a tap/press effect and interfered with scrolling over images, maps, and messages) and replaced it with a UIKit-backed `UILongPressGestureRecognizer` (`ScrollSafeLongPressModifier`, `cancelsTouchesInView = false`, `delaysTouchesBegan = false`, simultaneous with `UIScrollView`) plus no-highlight `ScrollFriendlyTapButtonStyle` on images, maps (`LocationCardView`), and reply quotes.
  - Made `jump-to-bottom` interrupt ongoing deceleration synchronously on the tap frame before converging; added and passed `HaloUITests.testTimelineImageScrollAndJumpToBottomWhileScrolling` on physical iPhone 16 (`00008140-000222592ED0801C`).

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
- **App:** `HaloSignpost`, `MetricPayloadStore`, `MetricKitRecorder`, `MainThreadHangs`; call sites in `HaloApp`, `AppRoot`, assemblies, `TimelineView`, `StickerImage`, `AsyncAnimatedImage`, `MatrixSessionPort` (also the measurement switches), NSE.
- **Tests (M17-8):** `SearchSpikeReader`, `SearchSpikeMeasurements`, `SearchSpikeEncryptionTests`, `SearchIndexMeasurements`. **Tests (M17):** `HaloSignpostTests`, `ImageDecodeSignpostTests`, `MetricPayloadStoreTests`, `MainThreadHangsTests`, `ScaleMeasurements`, `FaultTests`, `InteropTests`, `TestServerStage`, `HaloPerformanceTests` (the two perf tests moved out of `HaloUITests`).
- **Infrastructure:** `infra/test/`, `infra/dev/scale-fixtures.py` + compose/config, `tools/scenario-driver`, `scripts/{scale-measure,perf}.py`, `scenarios.yml`.
- **Docs (search, D123):** ADR-0024, MESSAGE_SEARCH and the documents it touches. **Docs (M17):** ROADMAP, OPEN_QUESTIONS, RISK_REGISTER, TEST_STRATEGY, INTEGRATION_TESTS, LOGGING, CI_CD, SYNC_ENGINE, PRIVACY, SECURITY, PRIVACY_POLICY, TECH_DEBT, DEVELOPMENT_SETUP, `infra/dev/README`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Waiting for the founder before work can pass a point**
- 👤 **Q-VERIFY** before M18 ends · **Q-REPORT**, **Q-SIGNUP**, **Q-REVIEW** later.

**Engineering (not blocking)** — the gaps are in ROADMAP §2, not repeated here.
- **`timeline` contract flake:** `verifyInteractions` timed out (90 s) in the first 3 of 12 completed full runs on the branch, then in none (one more run was stopped at 290 s, unfinished); 0 of 2 on `main` the same hour, 0 of 4 alone. The same test also timed out on earlier branches. The step is unknown; the tests now name it in the failure ("timed out …: never saw …").
- **Scale server:** `halo-scale` (about 1 GB) is left stopped or running on the dev Mac for M19; `infra/dev/scale-fixtures.py down` / `remove --yes`. Simulator `Halo Perf` belongs to `scripts/perf.py`.
- **Accessibility audit (watch):** `testLaunchRootScreenPassesAccessibilityAudit` failed at times until 2026-11-24 (also on `main`), "Potentially inaccessible text" without an element; 12 of 12 runs passed on 2026-11-25 with the cleaned-up account. Cause unknown, no exemption added.
- **Dev APNs stall (2026-11-24, 15:05–15:19 UTC):** APNs accepted pushes the iPhone never acted on (alerts and silent ones), then delivery resumed without a change; a later silent push also had no effect within 12 s (iOS throttles them; opening healed it). Cause unknown.
- **Account data (D120 limit):** two devices writing the same type in the same moment can still lose one change (Matrix has no conditional write).
- **`Halo (iPhone)` sessions on the dev accounts:** stickertester has 10, contractpeer 4 (the app's own sign-ins, some from reinstalls); which are live can't be told from the server, so nothing touches them: sign old ones out in Settings → Sessions. About 120 throwaway users from before 2026-11-25 (`e2ee…`, `scen_…`, `rules_…`) remain.
- **S29 server flake (was 1 of 8 runs):** Synapse rotated its push counts 90 ms before the receipt arrived and kept reporting the old count (its database was right). Not a Halo rule; the scenario now runs once more in a new room, only when the server's own sync still reports the wrong count.
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).

**Needs the founder (`👤`) or physical device (`📱`)**
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
1. Founder: merge PR #90; the device and hand checks of §5. M19-11 (search, with M20-1) may start.
2. M18 top to bottom (M19 may start too, D125). Re-run `infra/test/run.sh faults` for send and sync changes.
3. Founder, long lead times: push gateway (M22-1), legal (M22-4), KLIPY production key, filtering entitlement, artwork.

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
- infra/test/run.sh faults|interop when sending, sync or timeline mapping changes
- Never scale-test on stickertester or contractpeer; use the M17-3 accounts
- Update HANDOFF.md, ROADMAP.md and the owning spec in the last commit of every push (AGENTS.md §18).
```
