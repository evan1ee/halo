# Feature: Room Timeline

> Priority: P1 · Milestone: M1 (read-only), M2 (interactive) · Modules: FeatureTimeline, `TimelinePort`, HaloBotRendering, HaloDesignSystem · Requirements: R-P1-TL

## 1. Purpose
Show a room's history correctly and smoothly, and report what the user has actually seen.

## 2. User stories
- I open a room and land at the newest message; if some messages were unread, the first of them stays marked and a "Jump to unread" button takes me up to it (D95).
- I scroll back through history smoothly; media loads progressively.
- I see who has read what, edits, reactions, replies, and why a message can't be decrypted.

## 3. Functional requirements
- FR-1 Items from `Timeline.add_listener` diffs **[VERIFIED F-FFI-8]**, applied to an identity-stable array.
- FR-2 Item types: text (HTML subset rendered), notice, emote, image, video, audio, file, sticker, location (static: description + Maps link, built), poll (interactive card, built: vote, change vote, live results / undisclosed until end, end own poll; MESSAGING FR-10), redacted, UTD, state events (grouped, collapsible), call events (display only, D43; built), unknown (fallback "Unsupported event").
- FR-3 Back pagination on reaching the top (`paginate_backwards(20)`), with a status indicator.
- FR-4 Read-marker line at `m.fully_read`; "Jump to unread" pill when the line is above the viewport.
- FR-5 **Visibility tracking** → `ReadStateCoordinator.markRead` per D6 ([../matrix/READ_RECEIPTS.md](../matrix/READ_RECEIPTS.md) §1).
- FR-6a Delivery state of own messages, one model for every kind (text, photo, video, file, audio, sticker, location): sending = small spinner, sent (server confirmed) = circle with a check, read = the readers' avatars replace the check (tap for the list), failed = warning + "Not sent" with retry/delete. *Built (D107): `TimelineRow.Delivery`, `DeliveryIndicator`.*
- FR-6 Read receipts: up to 3 avatars + count under the newest message each user has read. *Built: up to 3 avatars + count under own sent messages (name/picture from the timeline's own senders, else the ID's name part); tap the avatars for the full list of readers (built, not seen on screen); not built: receipts under others' messages.*
- FR-7 Reactions row; tap toggles (`toggle_reaction`).
- FR-8 Reply preview (`load_reply_details`), tap to jump. A message that isn't loaded opens the timeline around it (M20-1: `timeline_with_configuration`, `TimelineFocus.Event` **[VERIFIED F-FFI-22]**), for replies, search hits, links, pins, notifications and Activity. Newer messages load at its end, and after the last one the live timeline comes back; a "Newest" button leads there at any time, and so does sending. While focused nothing is marked as read, and opening a room at a message waits with receipts until that message is shown. Gone or unreachable is said; without the server, up to ten pages of what the device holds are searched. Threads page back instead.
- FR-9 Edits show "(edited)"; long-press → "View edit history" (`edit_revisions`, F-FFI-22) (P2; built).
- FR-10 Bot messages from allowlisted senders go through `BotMessageRenderer` ([BOT_MESSAGES.md](BOT_MESSAGES.md)); all messages get "View source".
- FR-11 Threads: thread replies inline as replies (D17); a thread screen opens from its root (M10, built).
- FR-12 A changed identity of a contact shows as a notice (ENCRYPTION_AND_DEVICES FR-7, *not built*, ROADMAP M18-1).
- FR-13 Code blocks with copy, spoilers (`data-mx-spoiler`), and safe rendering of tables and lists (*not built*, ROADMAP M20-10).

## 4. Non-functional requirements
60 fps scrolling (NFR-2); a diff batch is applied within one frame; image decoding off the main thread; animated stickers pause off-screen. *Not met today:* a change rebuilds every row on the main actor, and photos are decoded in view bodies (ROADMAP M19-1, M19-2).
Opening a room shows no spinner (one appears only if opening takes over 1 s) and no frame of the room's top before it lands at the newest message (D95). A room chosen in the chat list starts its view model on the tap, and its screen is pushed once that model has landed at the newest row, or after 150 ms (`PreparedTimelines`, M19-9, D126), so the screen's first frame has its rows; such a model reports nothing about what was read until its screen is shown (READ_RECEIPTS §1), and lands at the newest row and reads the read position again at that moment. A newer tap replaces an older one. A row keeps its height once laid out: a photo's box has the size the event announces (4:3 when it announces none) and the picture fills it, because a lazy list that re-measures a row while scrolling to the newest message loses its place (seen in S10). While the list follows the newest message, history arriving above, a row that grows (a reaction) and the list settling its estimated row heights after the opening scroll keep the newest row fully in view above the composer ("at the bottom" counts the inset under the composer; seen in S10 scroll test, where the landing stopped with the newest message half hidden); any scroll movement (a drag, a fling, jumping to unread or to a reply) stops the following, so nothing pulls the reader back down. When scrolled up and earlier history pages prepend above the reader's position (and the user is not actively dragging), the list re-anchors at the previous top row (`PrependedAnchor`) instead of jumping to the start of the newly inserted page. A short room that fits on screen with no earlier history to load is anchored just above the composer via top scroll content margins (`ShortRoomAlignment`). The "Jump to unread" pill counts the first unread message as off screen until its row reports itself visible, because a room that lands 40 messages below it never lays that row out.

## 5. User flows
Open → position (newest message; first unread marked) → scroll → events become visible → intents → the list badge clears.

## 6. State transitions
`Opening → Positioned → Live`; `Live → PaginatingBack → Live`; `Live → Detached` (scrolled far up; new events show a "↓ N new" pill).

## 7. Data models
`TimelineItem { id: TimelineItemID, kind, sender, timestamp, isOwn, sendState, reactions, readBy, replyTo?, isEdited, eventId? }`; `TimelineDiff` (Halo enum mirroring append/insert/set/remove/reset).

## 8. API boundaries
`TimelinePort.open(room)` returns a `TimelineSession`; the view model never sees upstream types. Read reporting goes through `ReadStateCoordinator`.

## 9. Error scenarios
Pagination failure (retry button) · media download failure (retry tile) · timeline reset by the SDK (re-position on the same event).

## 10. Edge cases
A photo without a size (4:3 box, cropped) · a short room (fits on screen: pushed down to sit just above the composer by a top content margin computed as a fixed point — a List's scroll-geometry content height includes that margin and its top inset does not, measured 2026-11-23; a wrong assumption here made the margin flip on every layout pass and froze rooms holding only a few events at 100 % CPU; at most 8 margin changes a second as a guard) · a room without messages (only setup events: "No messages yet"; earlier pages are loaded by themselves until a message or the room's start is found) · gaps in history · an event-focused jump to a very old event · own message from another device · a redaction of an item in view · a room with only state events · rapid diffs during scrolling.

## 11. Acceptance criteria
- AC-TL-1 Opening a room with unread messages lands at the newest message and keeps the first unread one marked, with a "Jump to unread" button (D95).
- AC-TL-2 Viewing the newest message clears the room's attention (AC-U1).
- AC-TL-3 The timeline and the list agree (R-P0-3): if the list shows attention, the room is an invite, is marked unread, or the timeline has at least one event newer than `readPosTs` that notifies under the room's mode; conversely, if the timeline has such a notifying event, the list shows attention. Events that don't notify under the mode affect only `hasUnread` ([../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md) §5).
- AC-TL-4 No dropped frames in the scroll performance test (≥ 95 % frames on time).
- AC-TL-5 Jumping to an event 5,000 messages back shows it within 2 s online; offline or deleted, it says so, and "back to newest" returns to the live timeline.
- AC-TL-6 With 2,000 rows loaded, one new message rebuilds at most two rows.

## 12. Test requirements
Unit: diff application (randomised diff sequences vs a reference model), visibility tracker (dwell time, scene phase, partial visibility). Snapshot: every item type. Integration: S-TL-1..3.

## 13. Open questions
— (V-TL-1 resolved by F-FFI-22.)
