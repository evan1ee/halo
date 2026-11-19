# Feature: Room List

> Priority: P1 (indicators P0) · Milestone: M1 (list), M3 (indicators) · Modules: FeatureRoomList, `RoomListPort`, `ReadStateCoordinator` · Requirements: R-P1-LIST, R-P0-*

## 1. Purpose
Show every conversation, sorted by activity, with indicators you can trust.

## 2. User stories
- I see my rooms instantly from cache, newest activity first.
- A badge appears only when a room needs me; a bold title shows quiet unread.
- I can filter to Unread, People (DMs), Rooms, Favourites, Invites.
- I can swipe to mark read/unread, mute, favourite.

## 3. Functional requirements
- FR-1 Entries from `RoomList.entries_with_dynamic_adapters` with paging (`add_one_page`) **[VERIFIED F-FFI-5]**.
- FR-2 Filters via `RoomListDynamicEntriesController.set_filter` (filter kinds per `RoomListEntriesDynamicFilterKind` **[VERIFIED type exists; cases at M1]**).
- FR-3 Row: avatar, name, latest-event preview (`LatestEventValue`), timestamp, indicator from `RoomReadState` (`.count`, `.mentions`, `.dot`, none), muted icon, `hasUnread` bold.
- FR-4 The indicator comes **only** from `ReadStateCoordinator` (never from `RoomInfo` directly).
- FR-5 Invites section at the top; accept/decline.
- FR-6 Swipe actions: mark read (`ReadMarkerPort.sendReceipt` on the latest event + clear the flag), mark unread (`setMarkedUnread(true)`), mute (mode), favourite (room tag **[ASSUMPTION V-RL-1: tag API in FFI]**).
- FR-7 Sync indicator in the header (`sync_indicator`).
- FR-8 Pull-to-refresh is **not** provided (sync is continuous); a manual "Reconcile" exists under Diagnostics.

## 4. Non-functional requirements
NFR-1 (cold start ≤ 1 s for 300 rooms); diff application without full reloads; stable row identity (room id).

## 5. User flows
Launch → list from cache → sync updates rows in place → tap → timeline. Swipe → action → the row updates when the state returns.

## 6. State transitions
`Loading(cached) → Loaded → Updating`; filter changes reset paging. Indicator transitions follow [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md) §6.

## 7. Data models
`RoomSummary { id, name, avatar, isDirect, isEncrypted, latest: LatestEventPreview?, membership, isFavourite, mode }` +
`RoomReadState` joined by id in the view model.

## 8. API boundaries
`RoomListPort` (adapter), `ReadStateCoordinator` (application), `ReadMarkerPort` via use cases.

## 9. Error scenarios
Room list service error → banner + retry; action failures → toast with retry.

## 10. Edge cases
Room upgraded (tombstone) → show the successor; a DM with a left user; 0 rooms (empty state); very long names; a room in the list but `get_room` fails.

## 11. Acceptance criteria
- AC-RL-1 The badge on a row equals `RoomReadState.display` for that room in every test scenario.
- AC-RL-2 The order matches the SDK's sort (recency) after updates; no duplicate rows.
- AC-RL-3 Cold-start performance per NFR-1 (measured).

## 12. Test requirements
Unit: view-model diff application, filter switching, swipe actions with fakes. Snapshot: row variants (all indicator states, dark/light, AX sizes). Integration: S-RL-1 (list matches server rooms).

## 13. Open questions
V-RL-1.
