# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#75 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** **ALL autonomous engineering work across M0–M16, ADR-0022 steps 1–4 (D86), and Tech Debt Phases A–D is complete!** Only founder (`👤`) and physical-device (`📱`) items remain (listed in §5).
- **Milestones:** M0–M16 done except founder/device items (gates, Beta/Release push gateway + TestFlight, 7-day AC-U8 soak, physical-device NFR-1/NFR-2/MetricKit run, Q-BRAND sign-in artwork, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE, legal/export/privacy labels). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Last prepush:** `HALO_SIM="iPhone Air" scripts/prepush.sh` (Halo closed in every simulator first): all steps passed (`HaloCore` 187 tests, `HaloApple-Package`, `Halo-Debug` on `iPhone Air` + `iPad Pro 13-inch (M5)`, `HaloUITests`, docs/boundaries/tokens, gitleaks, swiftlint 0 violations).
- **CI:** PRs #1–#75 merged. Linux CI runs `HaloCore` tests; manual-dispatch `.github/workflows/macos-build.yml` (TD-04) runs full iOS Simulator tests + `HaloUITests` before TestFlight uploads.

## 2. Completed work (last 3 sessions)
Summary only; older history lives in `git log`.
- **M4/M5 sticker panel & pack creation simulator UI check (`main`):** verified `stickers` & `createPack` contract tests against `infra/dev` and added `HaloUITests.testStickerPanelAndPackCreationFlow` on signed-in `iPhone Air`; fixed Dynamic Type clipping, contrast (`HaloColor.bgPrimary`/`textPrimary`), `.accessibilityHidden(true)` on sticker placeholder text, and 44×44 `+` hit target in `StickerPanelView`/`NewPackView`.
- **M16 completion & timeline scroll follow-ups (`main`, `ae88d29..ce9073b`):**
  - iPad three-column layout (`RoomInfoPresentation` + `.inspector` column 300–420 pt + `⌘I`, sheet on compact/iPhone); `ChatsRouterSplitTests`.
  - Send-by-Siri (`SendMessageIntent` + `SiriSendCoordinator`, reuses D88 `ChatEntity`, confirmation before send, confirmed vs queued); `SiriSendCoordinatorTests`.
  - Drag items out of timeline (`TimelineDragExtractor`, `DraggedTimelineFile` for text/captions/notices/emotes, loaded photos, files ≤ 50 MiB); `TimelineDragTests`.
  - Timeline scroll follow-ups (`PrependedAnchor` preserves position on back-pagination; `ShortRoomAlignment` bottom-aligns short rooms above composer); `TimelineScrollHelpersTests`.
- **Signed-in chat-list accessibility audit & local signing (`PR #74–#75`):** `AvatarTint` contrast ≥ 4.5:1 (`AvatarTests`), wrapping Media Gallery row, 44 pt Focus banner button, full-list audit in `HaloUITests` (D96); `ios/Config/Local.xcconfig` keeps `DEVELOPMENT_TEAM` out of git; removed deprecated `UIWindow(frame:)` in `WebAuthSessionPresenter`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D96), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74 / D78–D80 (ADR-0020):** classic sync unread evidence, encrypted-room SDK counts decide, identity/timeline-index read ordering.
- **D82 (ADR-0021):** app icon badge sums `RoomReadState.badgeCount` for `attention == true`.
- **D83:** Global Media Gallery is a preset virtual room entry in the room list (not a tab, excluded from unread/badge).
- **D84 / D85 / D86 (ADR-0022):** Apple-native north star; single `NavigationStack` shell; module layout v2 (all 4 steps complete).
- **D95:** a room opens at its newest message; the first unread message stays marked and "Jump to unread" goes up to it.
- **D96:** the accessibility audit skips contrast under the floating search field and `element == nil` `.contrast`/`.textClipped` while that field is on screen; every resolved element above it still fails.

## 4. Modified files (this push)
- **Stickers UI & test + D96 audit update:** `FeatureStickers/{StickerPanelView,NewPackView}.swift`, `ios/UITests/HaloUITests.swift`, `docs/DECISION_LOG.md`, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Engineering (not blocking)**
- **Timeline follow-up:** the room appears ~150 ms after the push starts (the list is hidden until placed).

**Needs the founder (`👤`) or physical device (`📱`)**
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
1. Founder checks room opening on the device (`Halo-Debug` is installed on the iPhone) (§5 📱 "Opening rooms"); then the timeline follow-ups in §5 "Engineering".
2. Founder resolves §5 items (gates, push gateway / APNs, Q-BRAND sign-in illustration, Q-APPSTORE, legal/export/privacy labels) and runs Beta 1 (internal TestFlight) on a physical device.
3. Post-1.0 backlog (M16): all autonomous items complete (share extension, share-sheet sending, App Intents/Spotlight + Send-by-Siri, unread + unread-chats widgets, Focus filter, iPad two/three-column layout, keyboard shortcuts, drag-and-drop in and out). Calls will not be implemented (D94).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/ROADMAP.md (§"Remaining work").
All autonomous engineering work for M0–M16, ADR-0022 steps 1–4, and Tech Debt
Phases A–D is complete and on main.

Only founder (👤) and physical-device (📱) items remain in HANDOFF.md §5
(gates, Beta/Release push gateway + TestFlight, Q-BRAND sign-in artwork,
Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE, legal/export/privacy labels, 7-day
AC-U8 soak, and physical-device NFR-1/NFR-2 metrics).
Last pushes on main: timeline scroll anchor on prepend & short-room bottom
alignment, M16 drag out of timeline, M16 Send-by-Siri (SendMessageIntent +
SiriSendCoordinator), and M16 iPad three-column inspector layout (⌘I).
Next: check the device/founder items in HANDOFF §5, or pick any bug report
or release-prep task the founder raises.
Checks: HALO_SIM="iPhone Air" scripts/prepush.sh (close Halo in every
simulator first).
```
