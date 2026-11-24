# Halo — Session Handoff

Last updated: 2026-11-24 · Branch: `feat/field-encryption-pushkin-decisions` · PRs #1–#80 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** all autonomous work across M0–M16, ADR-0022, Tech Debt A–D (including TD-12), and the Halo Sygnal pushkin (`infra/sygnal/`, R-24) is complete; gates G-FFI, G-UNREAD, and G-NSE are confirmed PASS (D109). Only remaining founder (`👤`) and physical-device (`📱`) items live in §5.
- **Milestones:** M0–M16 done except remaining founder/device items (Beta/Release push gateway deploy + APNs keys + TestFlight, 7-day AC-U8 soak, physical-device NFR-1/NFR-2/MetricKit run, Q-KLIPY-PROD, Q-BRAND sign-in artwork, Q-APPSTORE, legal/export/privacy labels). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Last checks (`feat/field-encryption-pushkin-decisions`):** `infra/sygnal` pushkin unit tests (4/4), `validate-docs.sh`, `check-boundaries.sh`, `test_check_boundaries.py` (5/5), `check-design-tokens.sh`, `gitleaks`, `swiftlint --strict` (268 files, 0 violations), `HaloPersistenceTests` (including `FieldCipherTests`), and `Halo-Debug` simulator build all passed (`HaloUITests` not re-run; passed in PR #80).
- **CI:** PRs #1–#80 merged. Linux CI runs `HaloCore` tests; `.github/workflows/pushkin.yml` runs `infra/sygnal/` unit tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **Field encryption, Sygnal pushkin & founder decisions (2026-11-24, `feat/field-encryption-pushkin-decisions`, D108–D112):**
  - Implemented AES-256-GCM field encryption (`FieldCipher`, `KeychainItem.haloDatabaseKey`, `"enc:v1:"` envelopes with transparent plaintext read-through) for `draft.body`, `bot_task.title`, and `bot_task.detail` in `DraftStore`/`BotTaskStore`/`SessionAssembly`, with `FieldCipherTests` (closes TD-12 / R-16 / NFR-7, D108).
  - Implemented Halo Sygnal APNs pushkin in `infra/sygnal/` (`halo_pushkin.py`, `Dockerfile`, `sygnal.yaml.example`, `README.md`, `test_halo_pushkin.py`, `.github/workflows/pushkin.yml`, pinned to `matrixdotorg/sygnal:v0.15.1`; D112 / ADR-0015 Option 1).
  - Recorded founder decisions: confirmed PASS for G-FFI / G-UNREAD / G-NSE (D109), resolved `Q-ONBOARD-SERVER` (D110) and `Q-L10N` (D111).
- **UI test regressions, design tokens & doc cleanup (2026-11-24, PR #80):**
  - Fixed `HaloUITests` detecting the borderless Chats root header (`chatsRoot(app)` checks `app.buttons["settings"]`) and guarded `testComposerPanelsSwapWithKeyboard` with `requireSoftwareKeyboard(app)` when a hardware keyboard is attached (6 passed, 0 failures).
  - Fixed 4 `check-design-tokens.sh` violations (`HaloColor.onAccent`, `HaloTypography.caption`), removed dead `sleep` property from `RoomDetailsViewModel`, and cleaned stale notes in `OUTSTANDING_ISSUES.md` and `HANDOFF.md`.
- **Pin reload & jump-to-bottom arrow bug fixes (2026-11-24, `main`):**
  - Fixed pinned messages disappearing on room re-entry (`TimelineCoordinator.pinnedEventIDs()`, regression test `PinMessageTests.reenteringRoomKeepsPins`) and jump-to-bottom arrow disappearing on early scroll/jump in `TimelineView`.

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
- **Persistence & App (`HaloApple`, `ios/App`):** `HaloPersistence/{FieldCipher,DraftStore,BotTaskStore}.swift`, `Tests/HaloPersistenceTests/FieldCipherTests.swift`, `ios/App/Composition/SessionAssembly.swift`.
- **Pushkin & CI:** `infra/sygnal/{halo_pushkin.py,test_halo_pushkin.py,Dockerfile,sygnal.yaml.example,README.md}`, `.github/workflows/pushkin.yml`.
- **Docs:** `docs/DECISION_LOG.md`, `docs/testing/GATE_EVALUATION_M3.md`, `docs/adr/0015-count-only-pushes.md`, `docs/OPEN_QUESTIONS.md`, `docs/ROADMAP.md`, `docs/development/TECH_DEBT.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Engineering (not blocking)**
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).

**Needs the founder (`👤`) or physical device (`📱`)**
- 👤 **Q-KLIPY-PROD:** the KLIPY key is a testing key (100 requests/hour); request production access in KLIPY's Partner Panel before Beta 1. 👤 **Q-KLIPY-REHOST:** decide whether to ask KLIPY to approve sending GIFs as encrypted `m.image` instead of links.
- 📱 **UI tests on devices:** the iPhone 16 (`00008140-000222592ED0801C`, signed in as contractpeer on the LAN dev server) runs `HaloUITests` (composer, empty room, launch). The iPhone 17e still exited with code 74.
- 📱 **Location, polls and articles:** send own location and a pin on a device, start a poll, send an article with headings/lists/code; check they render in Halo and Element (no live message was sent in the simulator).
- 📱 **Voice messages on a device:** record, cancel and send one; check it plays in Halo and Element (the simulator has no microphone test here).
- 📱 **Composer panels on a device:** keyboard ↔ panel swap verified on the iPhone 16 (0.0 pt per frame); still open: iPad floating/hardware keyboard, the composer following the keyboard when it opens from nothing (only end positions measured), and a KLIPY GIF into an encrypted room seen in Element as a link (AC-CP3). The simulator here does not refresh its display without a viewer, so checks ran through XCUITest screenshots.
- 📱 **Opening rooms on the device (D95):** open S10 and other large rooms with photos 10+ times; each must land at the newest message with no frame of the room's top and no spinner; also from a notification tap and Spotlight, and in the iPad split view.
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (Beta/Release push gateway deploy):** deploy `infra/sygnal/` (D112) with APNs keys, verify V-PUSH-5 live, and upload Beta 1 to TestFlight.
- 👤 **UX/ship open questions (D84):** **Q-BRAND** (sign-in illustration; halo disc `AppIcon` landed), **Q-APPSTORE** (App Store metadata, privacy policy & support pages), legal review (D38), export compliance (V-LEGAL), privacy nutrition labels ([docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)).
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
- 📱 **Physical-device validation:** 7-day AC-U8 daily-driver soak, Release/TestFlight G-NSE spot check, NFR-1/NFR-2 XCTest metrics on iPhone 15-class device (`HALO_RUN_PERF_TESTS=1`), MetricKit hang/launch review, and Beta 1 → Beta 2 → 1.0 release.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. Review and merge `feat/field-encryption-pushkin-decisions` once CI passes.
2. Founder checks room opening, composer panels, voice/location/poll/article sending, iPad split/inspector, widgets, Focus filter, Siri/Spotlight, and Share extension on physical devices (§5 📱).
3. Founder resolves remaining §5 👤 items (deploy `infra/sygnal/` + APNs keys + V-PUSH-5, Q-KLIPY-PROD, Q-BRAND sign-in illustration, Q-APPSTORE, legal/export/privacy labels) and runs Beta 1 (internal TestFlight) on a physical device.
4. Post-1.0 backlog (M16): all autonomous items complete; calls will not be implemented (D94).

## 7. Next Session Prompt
```text
Read AGENTS.md and HANDOFF.md.
All autonomous engineering work across M0–M16, ADR-0022, Tech Debt A–D
(including TD-12 AES-GCM field encryption, D108), and the Halo Sygnal pushkin
(infra/sygnal/, D112) is complete; gates G-FFI/G-UNREAD/G-NSE are confirmed
PASS (D109). Latest branch: feat/field-encryption-pushkin-decisions.

Next:
1. If the feat/field-encryption-pushkin-decisions PR is open, check CI and merge.
2. Proceed with remaining founder/device items in HANDOFF.md §5 (Beta 1 push
   gateway deploy + V-PUSH-5, TestFlight, Q-BRAND, Q-APPSTORE) or new requests.
Checks: HALO_SIM="iPhone Air" scripts/prepush.sh (or isolated CLI DerivedData
under /tmp/halo-cli-dd when Xcode IDE is open).
```
