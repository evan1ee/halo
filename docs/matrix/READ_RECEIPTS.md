# Read Receipts and Read Markers

## 1. Sending

| Step | Rule |
|---|---|
| Trigger | The timeline reports the newest event that has been ≥ 50 % visible for ≥ 0.5 s while `scenePhase == .active` and the room is the top-most screen (D6) |
| Candidate | `TimelineReadTracker` selects the furthest visible event by **timeline index** (not `origin_server_ts`, **[DECISION D80, ADR-0020]**): never local echoes (no server event id yet), never hidden state events. When the user is viewing the tail row, targets `Timeline.latestEventId()` so trailing non-row events (e.g. encrypted poll votes, R-01 leftover) are covered |
| Monotonic | Ordered monotonically by `read_intent.timeline_order` (migration v8) when supplied by the open timeline, falling back to `originServerTs` across restarts (**[DECISION D80, ADR-0020]**; server zero never advances `readPosTs`) |
| Intent | Upsert `read_intent` in the same call → `ReadStateCoordinator` updates immediately |
| Send | `Room.send_single_receipt(.read or .readPrivate, .unthreaded, eventId)` **[VERIFIED F-FFI-6]**, then `Room.mark_as_fully_read_unchecked(eventId)` **[VERIFIED F-FFI-6]** |
| Receipt type | `.read` unless the privacy setting is "private receipts" → `.readPrivate` (D7) |
| Debounce | At most one send per room per 2 s; always the newest intent |
| Retry | Exponential backoff (1 s → 5 min), on reconnect, on foreground and on background flush |
| Confirmation | Sent intents stay in `read_intent` up to 7-day expiry so quiet-unread rooms keep their local read position (D72), **but** once confirmed (`ownReceiptEventID == intent.eventID` or after a sync epoch following send), E1 yields (`INTENT_STALE`) whenever countable server counts or SDK counts remain non-zero (**[DECISION D80, ADR-0020]**, revisiting D47/D72). Unsent intents never expire. Each failed send increments `attempts` and keeps `last_error` (the `HaloError` code); both reset when a newer event replaces the intent |

Why not `Timeline.mark_as_read(receiptType)` **[VERIFIED F-FFI-8]**? It picks "the latest visible event" from the
SDK's point of view, not what the user actually looked at; Halo needs D6 semantics. It can be used for an explicit
"Mark as read" action in the room list.

**Explicit actions**
- *Mark as read* (room list swipe): `ReadMarkerPort.markRoomRead(room)` calls `Room.markAsRead(receiptType:)` for the public/private receipt and `.fullyRead` (R-20), returns the receipted `EventID` (`loadUserReceipt` with fallback to `Timeline.latestEventId()`), and the coordinator records it as an intent in state `sent`. Then clear `m.marked_unread`.
- *Mark as unread*: `Room.set_unread_flag(true)` **[VERIFIED F-FFI-6]**.
- *Opening a room* clears `m.marked_unread` (`set_unread_flag(false)`) once the room is visible.
- *A timeline started ahead of its screen* (a room chosen in the chat list, started before its screen is pushed, M19-9, D126) sends nothing: no receipt, no own message as read, no `m.marked_unread` clearing, no draft or typing notice, until `TimelineViewModel.present()` (the screen appeared); then it behaves as a room just opened (`PreparedTimelinesTests`).
- *Sending a message*: write an intent at the own event (E1b) once it has a server event id.
- *Mark all as read* (settings, safety valve): `Client.mark_all_rooms_as_read` **[VERIFIED F-FFI-4]**.

## 2. Receiving
- Own receipts (from other devices) → the snapshot's `ownReceipt` via `Room.load_user_receipt(type, .unthreaded, ownUserId)` for both `.read` and `.readPrivate`; the later wins.
- Other users' receipts → timeline read-receipt avatars (provided by the timeline items; display only).
- The adapter refreshes `ownReceipt` when `RoomInfo` changes for that room (`subscribe_to_room_info_updates`) **[ASSUMPTION V-RS-1: RoomInfo updates fire when own receipts change]**.

## 3. Sync coverage
Since **[DECISION D74]** Halo uses classic `/sync` (`syncOnceV2`) rather than sliding sync, so receipts and account data arrive for **all joined rooms** without sliding-sync extension configuration (resolving the C3 sliding-sync extension gap; `V-RS-5` is superseded by D74). The server-zero rule (E2) remains the safety net.

## 4. Threads (until M10)
Send unthreaded receipts only. They cover all threads per spec v1.4 **[VERIFIED F-SPEC-1]**, so thread events are
read when the main timeline position passes them (D17).
