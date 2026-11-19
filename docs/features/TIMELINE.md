# Feature: Room Timeline

> Priority: P1 · Milestone: M1 (read-only), M2 (interactive) · Modules: FeatureTimeline, `TimelinePort`, HaloBotRendering, HaloDesignSystem · Requirements: R-P1-TL

## 1. Purpose
Show a room's history correctly and smoothly, and report what the user has actually seen.

## 2. User stories
- I open a room and land at the first unread message (or the bottom if all is read).
- I scroll back through history smoothly; media loads progressively.
- I see who has read what, edits, reactions, replies, and why a message can't be decrypted.

## 3. Functional requirements
- FR-1 Items from `Timeline.add_listener` diffs **[VERIFIED F-FFI-8]**, applied to an identity-stable array.
- FR-2 Item types: text (HTML subset rendered), notice, emote, image, video, audio, file, sticker, location (static), poll (read-only), redacted, UTD, state events (grouped, collapsible), call events (display only, D43), unknown (fallback "Unsupported event").
- FR-3 Back pagination on reaching the top (`paginate_backwards(20)`), with a status indicator.
- FR-4 Read-marker line at `m.fully_read`; "Jump to unread" pill when the line is above the viewport.
- FR-5 **Visibility tracking** → `ReadStateCoordinator.markRead` per D6 ([../matrix/READ_RECEIPTS.md](../matrix/READ_RECEIPTS.md) §1).
- FR-6 Read receipts: up to 3 avatars + count under the newest message each user has read.
- FR-7 Reactions row; tap toggles (`toggle_reaction`).
- FR-8 Reply preview (`load_reply_details`), tap to jump (paginate around the event if needed — `timeline_with_configuration` focus **[ASSUMPTION V-TL-1: event-focused timeline config available in FFI]**).
- FR-9 Edits show "(edited)"; long-press → "View edit history" (`edit_revisions`) (P2).
- FR-10 Bot messages from allowlisted senders go through `BotMessageRenderer` ([BOT_MESSAGES.md](BOT_MESSAGES.md)); all messages get "View source".
- FR-11 Threads: thread replies inline as replies (D17).

## 4. Non-functional requirements
60 fps scrolling (NFR-2); a diff batch is applied within one frame; image decoding off the main thread; animated stickers pause off-screen.

## 5. User flows
Open → position (first unread / bottom) → scroll → events become visible → intents → the list badge clears.

## 6. State transitions
`Opening → Positioned → Live`; `Live → PaginatingBack → Live`; `Live → Detached` (scrolled far up; new events show a "↓ N new" pill).

## 7. Data models
`TimelineItem { id: TimelineItemID, kind, sender, timestamp, isOwn, sendState, reactions, readBy, replyTo?, isEdited, eventId? }`; `TimelineDiff` (Halo enum mirroring append/insert/set/remove/reset).

## 8. API boundaries
`TimelinePort.open(room)` returns a `TimelineSession`; the view model never sees upstream types. Read reporting goes through `ReadStateCoordinator`.

## 9. Error scenarios
Pagination failure (retry button) · media download failure (retry tile) · timeline reset by the SDK (re-position on the same event).

## 10. Edge cases
Gaps in history · an event-focused jump to a very old event · own message from another device · a redaction of an item in view · a room with only state events · rapid diffs during scrolling.

## 11. Acceptance criteria
- AC-TL-1 Opening a room with unread messages positions at the read-marker line.
- AC-TL-2 Viewing the newest message clears the room's attention (AC-U1).
- AC-TL-3 The timeline and the list agree: if the list shows attention, the timeline has at least one event newer than the read position, and vice versa (R-P0-3).
- AC-TL-4 No dropped frames in the scroll performance test (≥ 95 % frames on time).

## 12. Test requirements
Unit: diff application (randomised diff sequences vs a reference model), visibility tracker (dwell time, scene phase, partial visibility). Snapshot: every item type. Integration: S-TL-1..3.

## 13. Open questions
V-TL-1.
