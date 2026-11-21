# ADR-0020: Order read state by event identity and timeline order, not timestamps

- **Status:** Accepted · **Date:** 2026-11-21 · **Decision IDs:** D80 (revises D47, D72) · **Validation:** gate G-UNREAD, scenarios S18, S29

## Context
D47 (ADR-0007) kept read-state comparisons purely timestamp-based (`latestEvent.ts <= localIntent.ts`) because `Room.latest_event()` in the upstream FFI carries no event ID **[VERIFIED F-FFI-15]**. D72 kept sent `read_intent` rows for 7 days. The codebase review (R-06) confirmed three missed-unread failure modes under that design:
1. Two messages with the same millisecond `origin_server_ts` (bots, bridges, batch imports): `TimelineViewModel` and `ReadReceiptCoordinator` dropped the second message, leaving the server count at 1 while E1 hid it for 7 days.
2. A federated sender with a slow clock sending after the user read: the later message had a smaller `origin_server_ts`, so timeline candidate selection and `ReadReceiptCoordinator` ignored it.
3. A sender with a future-skewed clock: reading that message prevented subsequent messages with normal timestamps from advancing the read position.

Additionally, R-01 left an open follow-up: encrypted non-message events (such as poll votes) sit after the newest visible message row, so receipting only visible rows leaves a stale server count (`ENC_SERVER_OVERCOUNT`).

## Problem
How do we eliminate timestamp-ordering failures in the read path and clear trailing non-row events without adding an independent event-cache recount (preserving ADR-0007)?

## Considered alternatives
1. **Identity + timeline order + bounded intent suppression (chosen):** use timeline index order inside open timelines (`TimelineReadTracker`), monotonic per-room `timeline_order` sequence on `read_intent`, event-ID comparison in E1 whenever both IDs are known, and yield E1 (`INTENT_STALE`) once a sent receipt is confirmed by the server/sync yet counts remain non-zero.
2. **Keep timestamp ordering with tie-breakers:** still fails under federated clock skew (both slow and fast clocks).
3. **Move to an independent Rust recount (G-FFI fail path):** unnecessary; the SDK's `Timeline` already exposes exact timeline order and `Timeline.latest_event_id()`.

## Decision
Option 1 (D80, revising D47 and D72):
1. Open timelines select receipt candidates strictly by **timeline index** (`TimelineReadTracker`), never by `origin_server_ts`. When the newest visible row is at the timeline tail, the receipt targets `Timeline.latestEventId()` so trailing non-row events (poll votes) are also covered without violating D6.
2. `read_intent` carries a per-room monotonic `timeline_order` column (migration `v8-read-intent-order`). Equal-millisecond and clock-skewed later events advance the intent and persist monotonically (preserving P8).
3. `RoomReadInputs` carries `localIntentEventID`, `localIntentConfirmed`, `ownReceiptEventID`, and optional `LatestEventRef.eventID`. In E1:
   - When both `localIntentEventID` and `latestEvent.eventID` are known, event identity decides (`==` covers; `!=` does not).
   - Once a sent intent is confirmed by the server (`ownReceiptEventID == localIntentEventID` or a sync completed after the send), any positive countable server count or positive SDK count overrides E1 with reason `INTENT_STALE`. Pending/unconfirmed intents continue to clear optimistically at once.

## Rationale
Eliminates equal-timestamp receipt drops and federated clock-skew blind spots while preserving instant optimistic clearing (S01, S11, S12, S24) and quiet-unread behaviour (S07b). Stays entirely on the upstream FFI binary.

## Trade-offs
Between sending a receipt and the next sync response (`!localIntentConfirmed`), when `LatestEventRef.eventID` is `nil` (from `Room.latestEvent()`), E1 still falls back to timestamp comparison for one sync round-trip; once confirmed, server/SDK counts immediately correct any skew.

## Consequences
- `HaloDatabase` adds append-only migration `v8-read-intent-order`.
- `ReadReceiptCoordinator` publishes `[RoomID: LocalReadPosition]` (event ID, timestamp, sent flag).
- `ReadStateCoordinator` tracks sync epochs to determine `localIntentConfirmed`.
- `TimelineReadTracker` owns visibility-to-receipt candidate selection in `FeatureTimeline`.
- Scenarios S18 (inverted) and S29 (equal timestamps) pin the behaviour.

## Verified facts and assumptions
- `Room.latest_event()` returns `LatestEventValue.remote` without an event ID **[VERIFIED F-FFI-15, pinned 26.11.17]**.
- `Room.load_user_receipt` returns `UserReceipt.eventId` **[VERIFIED F-FFI-15]**.
- `Timeline.latest_event_id()` returns the latest event ID in the timeline, including trailing non-row events **[VERIFIED F-FFI-15; vote clearing verified in `ClassicSyncEvidenceTests.encryptedNonMessageEvidence`, F-SDK-3]**.
