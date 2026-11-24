# Halo — Session Handoff

Last updated: 2026-11-24 · Branch: `perf/iphone16-ui-and-nfr-metrics` · PRs #1–#82 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** all autonomous work across M0–M16, ADR-0022, Tech Debt A–D (including TD-12), the Halo Sygnal pushkin (`infra/sygnal/`, R-24), and release documentation (`docs/release/`, D115) is complete; all open product decisions in `OPEN_QUESTIONS.md` are resolved (`D108–D117`). Physical iPhone 16 `HaloUITests` + NFR-1 cold launch (0.357 s responsive) + timeline memory (76.8 MB peak) baselines are recorded (`TEST_STRATEGY.md` §7). Only external-account / legal (`👤`) and remaining physical-device (`📱`) items remain (§5).
- **Milestones:** M0–M16 done except external/device items (deploy `infra/sygnal/` + APNs keys + TestFlight, 7-day AC-U8 soak, interactive Xcode/Instruments NFR-2 scroll hitch + 300-room + MetricKit run, Q-KLIPY-PROD portal request, publish `docs/release/` privacy/support URLs, final Beta 2 brand artwork, legal/export review). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`), physical iPhone 16 (`00008140-000222592ED0801C`, iOS 27.2.1).
- **Last checks (`perf/iphone16-ui-and-nfr-metrics`):** physical iPhone 16 `HaloUITests` + `TEST_RUNNER_HALO_RUN_PERF_TESTS=1` passed (0 failures across all 7 applicable device tests: launch audit, signed-in launch, sticker panel, composer panels swap, empty rooms, launch perf 0.348 s / 0.357 s responsive, timeline scroll memory 76.8–78.1 MB peak); `validate-docs.sh`, `check-boundaries.sh`, `check-design-tokens.sh`, `swiftlint --strict`, `gitleaks` passed.
- **CI:** PRs #1–#82 merged. Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **Physical iPhone 16 UI tests & NFR-1/memory baseline (2026-11-24, `perf/iphone16-ui-and-nfr-metrics`):**
  - Added `testTimelineScrollPerformanceMetric` (`XCTOSSignpostMetric.scrollingAndDecelerationMetric` + `XCTMemoryMetric`) and `XCTApplicationLaunchMetric(waitUntilResponsive: true)` to `ios/UITests/HaloUITests.swift`; fixed physical-device software-keyboard detection (`requireSoftwareKeyboard` checking any hittable key after settle) and `testEmptyRoomStaysResponsive` returning from a `@SceneStorage`-restored room.
  - Ran `HaloUITests` + `TEST_RUNNER_HALO_RUN_PERF_TESTS=1` on physical iPhone 16 (`00008140-000222592ED0801C`, iOS 27.2.1): 0 failures across all 7 applicable device tests; recorded NFR-1 launch (**0.348 s** / **0.357 s** responsive ≤ 1.0 s) and `S10` timeline peak memory (**76.8–78.1 MB** < 200 MB) in `docs/testing/TEST_STRATEGY.md` §7, `docs/design/UX_AUDIT.md`, and `docs/ROADMAP.md`.
- **Release docs & remaining founder decisions (2026-11-24, PR #82, D113–D117):**
  - Scaffolded `docs/release/{APP_STORE_METADATA,PRIVACY_POLICY,SUPPORT}.md` grounded in `PRIVACY.md` and `PrivacyInfo.xcprivacy` (D115).
  - Recorded founder decisions closing `Q-SDK-BUILD` (D113), `Q-CRASH` (D114), `Q-BRAND`/`Q-APPSTORE` Beta 1 (D115), `Q-KLIPY-REHOST` (D116), and `Q-MAS-ACCOUNT`/`Q-E2EE-STRATEGY`/`Q-BOT-OWNER`/`Q-ACT-REFRESH` (D117).
- **Field encryption, Sygnal pushkin & founder decisions (2026-11-24, PR #81, D108–D112):**
  - Implemented AES-256-GCM field encryption (`FieldCipher`, `KeychainItem.haloDatabaseKey`, `"enc:v1:"` envelopes) for `draft.body`, `bot_task.title`, and `bot_task.detail` with `FieldCipherTests` (closes TD-12 / R-16 / NFR-7, D108).
  - Implemented Halo Sygnal APNs pushkin in `infra/sygnal/` (`halo_pushkin.py`, `Dockerfile`, `sygnal.yaml.example`, `test_halo_pushkin.py`, `.github/workflows/pushkin.yml`; D112 / ADR-0015 Option 1); confirmed PASS for G-FFI / G-UNREAD / G-NSE (D109) and resolved `Q-ONBOARD-SERVER` (D110) / `Q-L10N` (D111).

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D107), [docs/adr/README.md](docs/adr/README.md).
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
- **UI & performance tests:** `ios/UITests/HaloUITests.swift`.
- **Docs:** `docs/testing/TEST_STRATEGY.md`, `docs/design/UX_AUDIT.md`, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Engineering (not blocking)**
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).

**Needs the founder (`👤`) or physical device (`📱`)**
- 👤 **Q-KLIPY-PROD:** the KLIPY key is a testing key (100 requests/hour); request production access in KLIPY's Partner Panel before Beta 1.
- 📱 **UI tests on devices:** the iPhone 16 (`00008140-000222592ED0801C`, signed in as contractpeer on the LAN dev server) runs `HaloUITests` (composer, empty room, launch). The iPhone 17e still exited with code 74.
- 📱 **Location, polls and articles:** send own location and a pin on a device, start a poll, send an article with headings/lists/code; check they render in Halo and Element (no live message was sent in the simulator).
- 📱 **Voice messages on a device:** record, cancel and send one; check it plays in Halo and Element (the simulator has no microphone test here).
- 📱 **Composer panels on a device:** keyboard ↔ panel swap verified on the iPhone 16 (0.0 pt per frame); still open: iPad floating/hardware keyboard, the composer following the keyboard when it opens from nothing (only end positions measured), and a KLIPY GIF into an encrypted room seen in Element as a link (AC-CP3). The simulator here does not refresh its display without a viewer, so checks ran through XCUITest screenshots.
- 📱 **Opening rooms on the device (D95):** open S10 and other large rooms with photos 10+ times; each must land at the newest message with no frame of the room's top and no spinner; also from a notification tap and Spotlight, and in the iPad split view.
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (Beta/Release push gateway deploy):** deploy `infra/sygnal/` (D112) with APNs keys, verify V-PUSH-5 live, and upload Beta 1 to TestFlight.
- 👤 **UX/ship external items (D84, D115):** publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md` with founder domain/contact, final Beta 2 brand artwork (`Q-BRAND`), legal review (D38), export compliance (V-LEGAL), and App Store Connect privacy nutrition labels.
- 📱 **Drag and drop (iPad):** drop a photo, a PDF and a link from Photos/Files/Safari into an open chat, and drag text, a photo, and a file out of a chat (also Split View with another app); a > 50 MiB file shows the size error.
- 📱 **Keyboard shortcuts (iPad/hardware keyboard):** ⌘N, ⌘,, ⌘F, ⌘1–⌘6 work and ⌘F focuses the search field.
- 📱 **Unread chats widget (device, D93):** add the medium widget with the setting on and off; names hidden on a locked screen.
- 📱 **V-SHARE-1 (device, ADR-0023):** share a photo and a link to an encrypted room from Photos/Safari with Halo closed, then with it running; one copy each, no undecryptable event; also signed out (fallback) and with Airplane mode (queued).
- 📱 **Share hand-back (device):** share a photo with notifications allowed, tap the notification, check "Send to…" appears; with notifications off the extension says to open Halo. Auto-opening Halo from the extension is not possible with public API; a chat picker inside the extension would be the alternative.
- 📱 **iPad on a device / dev homeserver (D91):** only the signed-out screen was checked in the iPad simulator. Check sidebar selection, trailing Room info inspector (button + ⌘I), Slide Over / Split View collapse to a sheet, rotation, and Settings/Stickers in the detail column.
- 📱 **Focus filter on a device (D90):** add Halo's filter to a Focus, toggle the Focus, check the list narrows, "Show all chats" works, and it restores when the Focus ends (also whether the system calls the intent on deactivation).
- 📱 **Widgets on a device (D89):** add the small and lock-screen widgets, receive a message and check the count refreshes; check the lock-screen redaction.
- 📱 **App Intents on a device (D88):** turn on "Chats in Siri and Spotlight", then say "Open <chat> in Halo", "Send a message to <chat> in Halo" (confirm online and offline), and tap a Spotlight result.
- 📱 **Share extension on a device (D87):** App Group sharing needs a signed build; check Safari link, several Photos, a Files PDF and a > 50 MiB file end to end. The simulator build only proves it compiles and the inbox logic.
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, interactive Xcode/Instruments NFR-2 scroll hitch ratio + 300-room NFR-1 check + MetricKit hang/launch review (dev-account iPhone 16 baseline recorded in `TEST_STRATEGY.md` §7: 0.357 s responsive launch, 76.8–78.1 MB peak memory), and Beta 1 → Beta 2 → 1.0 release.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. Founder deploys `infra/sygnal/` + APNs keys, requests KLIPY production access (`Q-KLIPY-PROD`), and uploads Beta 1 to internal TestFlight.
2. Founder runs physical-device checks in §5 📱 (room opening, composer panels, voice/location/poll/article sending, iPad split/inspector, widgets, Focus filter, Siri/Spotlight, Share extension, 7-day AC-U8 soak, NFR-1/NFR-2 perf).
3. Before Beta 2 / 1.0: publish `docs/release/{PRIVACY_POLICY,SUPPORT}.md`, finalize Beta 2 brand artwork, and complete legal/export compliance.

## 7. Next Session Prompt
```text
Read AGENTS.md and HANDOFF.md.
All autonomous engineering work, technical debt (including TD-12 AES-GCM
field encryption, D108), Halo Sygnal pushkin (infra/sygnal/, D112), gate
confirmations (D109), release docs (docs/release/, D115), and open product
decisions (D108–D117) are complete on main.

Next:
Proceed with physical-device / Beta 1 TestFlight checks in HANDOFF.md §5,
or any new feature, polish, or bug fix requested by the founder.
Checks: HALO_SIM="iPhone Air" scripts/prepush.sh (or isolated CLI DerivedData
under /tmp/halo-cli-dd when Xcode IDE is open).
```
