# Feature: Composer and keyboard panels

> Priority: P1 (post-1.0 polish, M16) · Milestone: M16 · Owner modules: `HaloDesignSystem/InputPanel`, `FeatureTimeline` (composer, emoji and attachment panels), `FeatureStickers` (sticker tab, KLIPY grids), `HaloDomain/Klipy`, `HaloDomain/Emoji/EmojiKeyboard`, `HaloApplication/Klipy`, `HaloPlatform/Klipy*` · Decisions: D97, D98 · Related: [STICKERS](STICKERS.md), [MESSAGING](MESSAGING.md), [MEDIA_ATTACHMENTS](MEDIA_ATTACHMENTS.md)

## 1. Purpose
One messaging input in the spirit of Telegram's, built natively in SwiftUI and in Halo's own look (Liquid Glass controls,
Halo tokens): the system keyboard and Halo's own panels (emoji, stickers, GIFs, attachments) take turns in the same
place under the composer, with no jumps while they swap.

## 2. User stories and user flows
- I tap the field and type with the iOS keyboard (dictation, predictive text, other languages: all native).
- I tap the sticker/smiley button inside the field and the keyboard turns into the emoji/sticker/GIF panel at the same height; tapping it again (now a keyboard icon) brings the keyboard back.
- In the panel I switch GIFs · Stickers · Emoji with a floating pill; the last tab is remembered.
- I search GIFs and KLIPY stickers, keep favourites, and find what I sent recently.
- I long-press a GIF or sticker to preview it, send it or favourite it.
- I tap the paperclip and pick photos from an inline picker, a file, or a pasted image.
- Dragging or tapping the conversation puts the keyboard or panel away.

## 3. Functional requirements: input state (D97)
`ComposerInputState` (pure, `HaloDesignSystem/InputPanel`) is the single source of truth for what is under the composer:
`idle`, `keyboard` or `panel(expression | attachments)`, plus `panelSearching` (a field inside the panel raised the
keyboard) and `lingeringPanel` (the panel being replaced while the keyboard rises). `ComposerInputController` drives it
from the field's focus, the composer's toggles and UIKit keyboard notifications.

```mermaid
stateDiagram-v2
  [*] --> idle
  idle --> keyboard: field focused
  idle --> panel: toggle(panel)
  keyboard --> panel: toggle(panel)
  panel --> keyboard: toggle(same panel) / field focused
  panel --> panel: toggle(other panel)
  keyboard --> idle: keyboard hides (interactive dismissal)
  panel --> idle: tap/drag on conversation
  keyboard --> idle: tap/drag on conversation
```

- **No jump.** The panel's height is the docked keyboard's last height above the bottom safe area (250–420 pt; 250 before any keyboard was seen; a hardware keyboard's shortcut bar never shrinks it). While the keyboard animates out (panel opening) or in (panel replaced), the panel area gives up exactly what the keyboard covers (`ComposerPanelMetrics.areaHeight`), animated with the keyboard's own curve, so keyboard + panel stays constant. The replaced panel stays drawn under the rising keyboard until it is covered.
- **Search inside a panel** raises the keyboard; the panel shrinks to its search height (190 pt) above it and its tab pill hides.
- **Composer independence.** The composer reads the mode only for its two toggle icons (paperclip ↔ keyboard, sticker/smiley ↔ keyboard) and sends events; panels insert or send through the timeline's view model and never reference the composer.

## 4. Emoji panel
The full emoji set from `EmojiKeyboard` (HaloDomain): sections by Unicode block (Smileys & People, Animals & Nature,
Food & Drink, Activity, Travel & Places, Objects, Symbols, Flags), only scalars with default emoji presentation, each
listed once; flags from ISO 3166 codes. Recently used first; a category strip jumps to a section; search matches curated
shortcodes, then word prefixes of Unicode names. Tapping inserts and keeps the panel open; a delete key removes one
whole emoji (flags and ZWJ families included). VoiceOver reads names.

## 5. Sticker tab
"My stickers" is the existing sticker panel (STICKERS §4) embedded in place of a sheet: sending keeps the panel open, and
the one-time "sticker images aren't encrypted" notice for encrypted rooms (STICKERS §3) is unchanged. With a KLIPY key a
segmented control adds the **KLIPY** source (a separate grid, D98); the choice is remembered.

## 6. GIFs and KLIPY stickers (D98)
KLIPY ([VERIFIED F-KLIPY-1]) provides GIF and sticker search. Its integration rules decide the design:

| Rule (KLIPY) | Halo |
|---|---|
| Load media directly from the returned URLs; never store, mirror, re-host or alter them | Previews and messages load from KLIPY's CDN through an ephemeral `URLSession`; media is held only in a 48 MB memory cache; nothing is written to disk |
| Requests come from the end-user client | `KlipyClient` (HaloPlatform) calls `api.klipy.com` from the device; no proxy |
| Keep search/trending order and composition; no blending with other sources | Trending/search pages are shown in KLIPY's order in their own grid; Halo packs and KLIPY are separate sources |
| "Search KLIPY" placeholder (required); "Powered by KLIPY" (optional) | Both |
| Share trigger | After a successful send, `POST …/share/{slug}` with the search text (best effort) |

**Sending.** A GIF or KLIPY sticker is sent as an ordinary text message whose body is the item's KLIPY media URL,
unchanged (a medium GIF for GIFs, a medium WebP for stickers). It goes through the SDK like any message, so it is
**end-to-end encrypted in encrypted rooms**; the media itself is public KLIPY content, never the user's. Re-uploading the
file as an encrypted `m.image` would re-host KLIPY media, which its rules forbid without written approval (Q-KLIPY-REHOST).

**Rendering.** A message whose whole text is one https KLIPY media link (`KlipyLink`) plays inline without a bubble,
at most 220 pt wide, only when KLIPY is configured and the room's media previews are on; otherwise it stays a link. Other
clients show the link.

**Data sent to KLIPY.** The app key, the search text, the device region, `content_filter=medium`, and `customer_id`, a
random per-install UUID (never a Matrix ID). Loading media tells KLIPY's CDN the device's IP address, like any link
preview; recipients' Halo loads it too (only with previews allowed). See [PRIVACY](../security/PRIVACY.md) §2.

**Favourites and Recent** (`KlipyShelf`) are kept on the device per account (UserDefaults, keyed by a hash of the user
ID): item metadata and URLs only, at most 200 favourites and 30 recents; dropped from memory on sign-out (D69).

**Key.** `HALO_KLIPY_API_KEY` in the git-ignored `ios/Config/Local.xcconfig` → Info.plist `HaloKlipyAPIKey`. Without it the
GIF tab and the KLIPY source are hidden and KLIPY links stay links. A client-side key is visible in the app binary by
design (KLIPY requires client-side calls); its limits live in KLIPY's Partner Panel. A testing key allows 100 requests per
hour (Q-KLIPY-PROD).

## 7. Attachment panel
An inline system Photos picker (`PhotosPicker`, `.inline`, continuous ordered selection; no photo-library permission is
needed) whose checked photos join the composer's pending strip (M13 batching, caption on the first); unchecking removes
them. Floating actions: **File** (Files picker, ≤ 50 MiB as before) and **Paste** when the clipboard has an image. GIFs
picked from Photos keep their animation (ImagePreparer).

## 8. Data models and API boundaries
| Piece | Module | Uses |
|---|---|---|
| `ComposerInputState`, `ComposerPanelMetrics`, `ComposerInputController`, `ComposerPanelArea`, `PanelTabPill`, `ComposerCircleButton`, `PanelSearchField`, `AsyncAnimatedImage` | HaloDesignSystem | SwiftUI, UIKit keyboard notifications |
| `Composer`, `ExpressionPanel`, `EmojiPanel`, `AttachmentPanel`, `KlipyMessageMedia` | FeatureTimeline | `TimelineViewModel` (`sendKlipy`, `insertEmoji`, `deleteBackward`, `attachPhoto`, `sendFile`) |
| `StickerTabView`, `KlipyPanelView`, `KlipyPanelModel`, embedded `StickerPanelView` | FeatureStickers | `KlipyCatalog`, `StickerPanelViewModel` |
| `KlipyKind/Item/Rendition/Page`, `KlipyResponseParser`, `KlipyLink`, `KlipyShelf`, `KlipyPort`, `KlipyShelfPort`, `EmojiKeyboard` | HaloDomain | — |
| `KlipyCatalog` (actor) | HaloApplication | `KlipyPort`, `KlipyShelfPort` |
| `KlipyClient`, `KlipyShelfStore` | HaloPlatform | URLSession (ephemeral), UserDefaults |
The composition root injects the Stickers and GIFs tabs into `TimelineView` as closures (features never import each other).

## 9. Error scenarios
KLIPY unreachable or slow → the grid shows a spinner, then "Couldn't load GIFs" with Try again · send fails → the panel stays open with "Can't reach the server. It wasn't sent." · share trigger fails → ignored · a preview fails → its tile stays a placeholder · a KLIPY message's media fails → the link is shown.

## 10. Non-functional requirements and edge cases
Panels appear within one frame of the tap (no loading for emoji; KLIPY grids show placeholders until previews arrive); grid previews are decoded off the main thread at tile size with at most 40 frames each, and KLIPY media stays within a 48 MB memory cache.

Hardware keyboard (no docked keyboard: panels use the minimum height, focus timeout clears the lingering panel) · iPad split views and floating keyboards (overlap measured against the key window) · Reduce Motion / Low Power Mode (first frame only) · a page repeating an item (shown once) · ads or items without usable files in a KLIPY page (skipped) · a thread timeline (emoji and attachments only).

## 11. Acceptance criteria
- AC-CP1 Switching keyboard ↔ panel keeps the composer at the same height (no visible jump) on iPhone.
- AC-CP2 An emoji, a Halo sticker and a KLIPY GIF can each be sent within two taps of opening the panel.
- AC-CP3 A KLIPY GIF sent into an encrypted room arrives as an encrypted message whose body is the KLIPY URL; Halo shows it animated, Element shows the link.
- AC-CP4 No KLIPY media file is written to disk (ephemeral session, memory cache only).

## 12. Test requirements
Unit: `ComposerInputStateTests` (transitions, hand-over sum), `ComposerInputControllerTests`, `EmojiKeyboardTests`, `KlipyModelsTests` (parser against a real response shape, links, shelf), `KlipyCatalogTests`, `KlipyClientTests`/`KlipyShelfStoreTests`, `KlipyPanelModelTests`, `ComposerKlipyTests` (send URL, refuse others, row detection, gating, delete). UI: `HaloUITests.testComposerPanelsSwapWithKeyboard`, `testStickerPanelAndPackCreationFlow`. Device (📱): AC-CP1 feel on hardware, AC-CP3 against Element.

## 13. Open questions
Q-KLIPY-REHOST, Q-KLIPY-PROD ([OPEN_QUESTIONS](../OPEN_QUESTIONS.md)).
