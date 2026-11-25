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
- FR-1 Entries from `Client.rooms()` (joined and invited, spaces excluded), rebuilt for the rooms each classic `/sync` response names (D74; `RoomListService` is sliding sync and isn't used).
- FR-2 Filters are applied by the adapter over the summaries.
- FR-3 Row: avatar, name, latest-event preview (`LatestEventValue`), timestamp, indicator from `RoomReadState` (`.count`, `.mentions`, `.dot`, none), muted icon, `hasUnread` bold.
- FR-4 The indicator comes **only** from `ReadStateCoordinator` (never from `RoomInfo` directly).
- FR-5 Invites section at the top; accept/decline.
- FR-6 Swipe actions: mark read (`ReadMarkerPort.markRoomRead(room)` + clear the flag — see READ_RECEIPTS §1), mark unread (`setMarkedUnread(true)`), mute (mode), favourite (`Room.set_is_favourite` **[VERIFIED F-FFI-18]**).
- FR-7 Sync indicator in the header (`sync_indicator`).
- FR-8 Pull to refresh runs a sync round trip (built; DESIGN_SYSTEM §11); a manual "Reconcile" also exists under Diagnostics.
- FR-9 **Preset Global Media Gallery entry** **[DECISION D83]**: the room list presents a preset virtual room entry for the global media gallery (D34, R-P2-GALLERY) instead of a dedicated tab. It is strictly a local UI entry—**not** a Matrix room (no server room ID, no Matrix sync state, excluded from `ReadStateCoordinator` / unread counts / app badge, and does not expose Matrix room actions such as mark read/unread, mute, room details, or leave). Tapping it opens the global media gallery view to display and organize media across rooms.

## 4. Non-functional requirements
NFR-1 (cold start ≤ 1 s for 300 rooms); diff application without full reloads (*not met: the list is sent as one reset on every change*, ROADMAP M19-3); stable row identity (room id).

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
Room upgraded (tombstone) → show the successor (*not built*, ROADMAP M20-8); a DM with a left user; 0 rooms (empty state); very long names; a room in the list but `get_room` fails.

## 11. Acceptance criteria
- AC-RL-1 The badge on a row equals `RoomReadState.display` for that room in every test scenario.
- AC-RL-2 The order matches the SDK's sort (recency) after updates; no duplicate rows.
- AC-RL-3 Cold-start performance per NFR-1 (measured).
- AC-RL-4 With 1,000 rooms, a change in one room updates one row and moves at most that row.

## 12. Test requirements
Unit: view-model diff application, filter switching, swipe actions with fakes. Snapshot: row variants (all indicator states, dark/light, AX sizes). Integration: S-RL-1 (list matches server rooms).

## 13. Open questions
V-RL-1.
