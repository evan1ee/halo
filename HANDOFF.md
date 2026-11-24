# Halo — Session Handoff

Last updated: 2026-11-24 · Branch: `main` · PRs #1–#79 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** all autonomous work across M0–M16, ADR-0022 and Tech Debt A–D is done; PRs #78 and #79 merged iOS 26 UX polish, the full Sticker Pack Manager, upgraded Photo Viewer, and Pinned Messages into `main`. Only founder (`👤`) and physical-device (`📱`) items remain (§5).
- **Milestones:** M0–M16 done except founder/device items (gates, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, physical-device NFR-1/NFR-2/MetricKit run, Q-BRAND sign-in artwork, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE, legal/export/privacy labels). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Last checks (PR #79):** `validate-docs.sh`, `check-boundaries.sh`, `gitleaks`, `HaloCore` (194 tests), `HaloDesignSystemTests`, `FeatureStickersTests` (20 tests), `FeatureTimelineTests` (100 tests), `Halo-Debug` build, and all 5 GitHub CI checks passed (`HaloUITests` not run).
- **CI:** PRs #1–#79 merged. Linux CI runs `HaloCore` tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **Pin reload & jump-to-bottom arrow bug fixes (2026-11-24, `main`):**
  - Fixed pinned messages disappearing on room re-entry: `TimelineCoordinator.pinnedEventIDs()` no longer gates on `case .live = status` (it was returning `[]` during `.opening` right after `open()`), with regression test `PinMessageTests.reenteringRoomKeepsPins`.
  - Fixed jump-to-bottom arrow disappearing on early scroll or jump in `TimelineView`: marks `landed = true` on user scroll interaction / `jumpRequest`, always syncs `model.setAtBottom(atBottom)` when `landed && model.isAtBottom != atBottom`, and checks `(!model.isAtBottom || !bottomVisible)`.
- **iOS 26 UX, Sticker Pack Manager, Photo Viewer & Pinned Messages (2026-11-24, PR #79):**
  - Tiered native confirmations (`.alert` for high-stakes actions, anchored `.confirmationDialog` on trigger), sheet grabbers (Room Info, Quick Look), and non-blocking floating Liquid Glass title pills on Stickers, Pack Detail, Settings, Acknowledgements, and Media Gallery (dynamic date pill + grouped type/room filter pill).
  - Full Sticker Pack Manager (`StickerPackManagementPort`, `StickerPackManager`, `StickerLibraryView`, `StickerPackDetailView`, `AddToStickerPackSheet`) with thumbnail preview strips, rename, add/delete stickers, and delete pack.
  - Timeline `LocationCardView` (`MKMapSnapshotter`), full-width photos, message-only long-press `MessageActionsSheet`, room-wide + `one.mbm.halo.pinned_events` personal pins with swipeable toolbar pin pill & `PinnedMessagesSheet`, VisionKit Live Text/Subject Lift + Save/Copy/Reply/React/Save-as-Sticker in `PagedPhotoViewer`, and `SendMessageIntent` deprecation fix.
- **Room list, avatar, floating header, jump button & gallery grid polish (2026-11-24, PR #78):**
  - Plain room list with text-aligned dividers, borderless `52 pt` avatars, stacked unread indicator, 2-line sender-prefixed previews, exact `44 × 44` circular Liquid Glass toolbar avatars (warning border replaces `verify-dot`), non-blocking headers, `34 × 34` glass jump-to-bottom button, and fixed `GlobalMediaGalleryView` tile clipping at `400` px.
- **Seamless photo send + unified delivery state (2026-11-24, D107):**
  - Added `TimelineDiffCoalescer` (folds echo `remove` + `pushBack` into one `set`), `TimelineThumbnailMemory` (no blank reload on confirmation), and unified `TimelineRow.Delivery` / `DeliveryIndicator` (spinner → check → readers' avatars) with unit, contract, and UI regression tests.

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
- **Application (`HaloCore`):** `HaloApplication/Timeline/TimelineCoordinator.swift`.
- **Feature (`HaloApple`):** `FeatureTimeline/TimelineView.swift`, `Tests/FeatureTimelineTests/PinMessageTests.swift`.
- **Docs:** `HANDOFF.md`.

## 5. Outstanding issues
- **UI flakes:** `testComposerPanelsSwapWithKeyboard` and `testEmptyRoomStaysResponsive` still fail in the full UI run (pre-existing); an own thumbnail is downloaded once after an app restart (SDK caches the file under the new reference, thumbnails under their own key).
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Engineering (not blocking)**
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed).

**Needs the founder (`👤`) or physical device (`📱`)**
- 👤 **Q-KLIPY-PROD:** the KLIPY key is a testing key (100 requests/hour); request production access in KLIPY's Partner Panel before Beta 1. 👤 **Q-KLIPY-REHOST:** decide whether to ask KLIPY to approve sending GIFs as encrypted `m.image` instead of links.
- 👤 **Merge PR #76:** all CI checks pass and prepush passed, but it adds a new third-party data flow (KLIPY, SECURITY/PRIVACY docs), which AUTONOMOUS_LOOP §3.4 leaves to the founder. Merge with `gh pr merge 76 --merge --delete-branch` once approved.
- 📱 **UI tests on devices:** the iPhone 16 (`00008140-000222592ED0801C`, signed in as contractpeer on the LAN dev server) runs `HaloUITests` (composer, empty room, launch). The iPhone 17e still exited with code 74.
- 📱 **Location, polls and articles:** send own location and a pin on a device, start a poll, send an article with headings/lists/code; check they render in Halo and Element (no live message was sent in the simulator).
- 📱 **Voice messages on a device:** record, cancel and send one; check it plays in Halo and Element (the simulator has no microphone test here).
- 📱 **Composer panels on a device:** keyboard ↔ panel swap verified on the iPhone 16 (0.0 pt per frame); still open: iPad floating/hardware keyboard, the composer following the keyboard when it opens from nothing (only end positions measured), and a KLIPY GIF into an encrypted room seen in Element as a link (AC-CP3). The simulator here does not refresh its display without a viewer, so checks ran through XCUITest screenshots.
- 📱 **Opening rooms on the device (D95):** open S10 and other large rooms with photos 10+ times; each must land at the newest message with no frame of the room's top and no spinner; also from a notification tap and Spotlight, and in the iPad split view.
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4).
- 👤 **R-14 (filtering entitlement):** request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3).
- 👤 **R-16 (DB field encryption):** decide AES-GCM field encryption (`KeychainItem.haloDatabaseKey`) vs plaintext under `completeUntilFirstUserAuthentication` with an ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** `SyncSettingsV2` filter and queued `sendRaw`/`sendSticker` need upstream `matrix-rust-sdk` PR + SDK bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide `infra/sygnal/` pushkin vs amending ADR-0015; configure Beta/Release push gateway + APNs keys + TestFlight.
- 👤 **UX/ship open questions (D84):** **Q-BRAND** (sign-in illustration; halo disc `AppIcon` landed), **Q-ONBOARD-SERVER**, **Q-L10N**, **Q-APPSTORE** (App Store metadata, privacy policy & support pages), legal review (D38), export compliance (V-LEGAL), privacy nutrition labels ([docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md)).
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
0. Merge the `feat/keyboard-panels` PR once checks pass; founder tries the panels on the iPhone and requests KLIPY production access.
1. Founder checks room opening on the device (`Halo-Debug` is installed on the iPhone) (§5 📱 "Opening rooms"); then the timeline follow-ups in §5 "Engineering".
2. Founder resolves §5 items (gates, push gateway / APNs, Q-BRAND sign-in illustration, Q-APPSTORE, legal/export/privacy labels) and runs Beta 1 (internal TestFlight) on a physical device.
3. Post-1.0 backlog (M16): all autonomous items complete (share extension, share-sheet sending, App Intents/Spotlight + Send-by-Siri, unread + unread-chats widgets, Focus filter, iPad two/three-column layout, keyboard shortcuts, drag-and-drop in and out). Calls will not be implemented (D94).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/features/COMPOSER_PANELS.md.
Last push: composer and keyboard panels (D97) with KLIPY GIF/sticker
search (D98) on branch feat/keyboard-panels (PR open). KLIPY needs
HALO_KLIPY_API_KEY in the git-ignored ios/Config/Local.xcconfig.

Next:
1. If the PR is still open: check its CI, merge per AUTONOMOUS_LOOP §3.
2. Device checks in HANDOFF §5 (composer panels AC-CP1/AC-CP3; simulator: composer at 513 pt with keyboard, panel and back, 0 pt drift), then the
   other founder/device items there.
3. Q-KLIPY-PROD / Q-KLIPY-REHOST are founder decisions; don't change the
   link-sending design without one.
Simulator note: drive UI through XCUITest (screenshots as attachments);
the headless simulator display may not refresh for direct screenshots.
Checks: HALO_SIM="iPhone Air" scripts/prepush.sh (close Halo in every
simulator first).
```
