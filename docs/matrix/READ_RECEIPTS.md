# Read Receipts and Read Markers

## 1. Sending

| Step | Rule |
|---|---|
| Trigger | The timeline reports the newest event that has been ≥ 50 % visible for ≥ 0.5 s while `scenePhase == .active` and the room is the top-most screen (D6) |
| Candidate | Only events that may carry receipts: not local echoes (no event id yet), not state events hidden from the user **[ASSUMPTION V-RS-4: receipts on hidden events are accepted by Synapse but may confuse counting; target the latest *visible* event]** |
| Monotonic | Ignore a candidate whose `originServerTs` ≤ the current `readPosTs` |
| Intent | Upsert `read_intent` in the same call → the policy updates immediately |
| Send | `Room.send_single_receipt(.read or .readPrivate, .unthreaded, eventId)` **[VERIFIED F-FFI-6]**, then `Room.mark_as_fully_read_unchecked(eventId)` **[VERIFIED F-FFI-6]** |
| Receipt type | `.read` unless the privacy setting is "private receipts" → `.readPrivate` (D7) |
| Debounce | At most one send per room per 2 s; always the newest intent |
| Retry | Exponential backoff (1 s → 5 min), on reconnect, on foreground and on background flush |
| Confirmation | After the server acknowledged the send (state `sent`), the intent is deleted when **(a)** `ownReceipt.eventId == intent.eventId`, or **(b)** a snapshot shows server counts = 0 and `latestEvent.ts ≤ intent.eventTs`, or **(c)** a newer intent replaces it. A `sent` intent older than 7 days is deleted (expiry). Unsent intents never expire |

Why not `Timeline.mark_as_read(receiptType)` **[VERIFIED F-FFI-8]**? It picks "the latest visible event" from the
SDK's point of view, not what the user actually looked at; Halo needs D6 semantics. It can be used for an explicit
"Mark as read" action in the room list.

**Explicit actions**
- *Mark as read* (room list swipe): the room list has no event id for the latest event (F-FFI-15), so `ReadMarkerPort.markRoomRead(room)` lets the adapter resolve it (`Timeline.latest_event_id()` on a short-lived timeline, F-FFI-15), send the receipt + fully-read marker, and return the `EventRef`; the coordinator records it as an intent in state `sent`. Then clear `m.marked_unread`.
- *Mark as unread*: `Room.set_unread_flag(true)` **[VERIFIED F-FFI-6]**.
- *Opening a room* clears `m.marked_unread` (`set_unread_flag(false)`) once the room is visible.
- *Sending a message*: write an intent at the own event (E1b) once it has a server event id.
- *Mark all as read* (settings, safety valve): `Client.mark_all_rooms_as_read` **[VERIFIED F-FFI-4]**.

## 2. Receiving
- Own receipts (from other devices) → the snapshot's `ownReceipt` via `Room.load_user_receipt(type, .unthreaded, ownUserId)` for both `.read` and `.readPrivate`; the later wins.
- Other users' receipts → timeline read-receipt avatars (provided by the timeline items; display only).
- The adapter refreshes `ownReceipt` when `RoomInfo` changes for that room (`subscribe_to_room_info_updates`) **[ASSUMPTION V-RS-1: RoomInfo updates fire when own receipts change]**.

## 3. Sliding-sync coverage
The receipts and account-data extensions must cover **all rooms in the room list**, not just open ones, or
own receipts from other devices are missed (cause C3). The room-list configuration is owned by
`matrix-sdk-ui`'s `RoomListService`; Halo can't currently configure extensions through the FFI.
**[OPEN V-RS-5]**: verify on the dev Synapse which extensions `RoomListService` enables for which rooms. The server-zero
rule (E2) is the safety net either way.

## 4. Threads (until M10)
Send unthreaded receipts only. They cover all threads per spec v1.4 **[VERIFIED F-SPEC-1]**, so thread events are
read when the main timeline position passes them (D17).
