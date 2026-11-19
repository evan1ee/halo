# Ports — the Stable Swift ⇄ Matrix Contract

Decisions: D44, ADR-0004. Ports live in `HaloDomain/Ports/`. They are **Halo-owned**: designed for Halo's
needs, made of Halo value types, and independent of the SDK version underneath.

## 1. Design rules
1. Parameters and results are `Sendable` value types defined in `HaloDomain` (`RoomID`, `EventID`, `UserID`, `RoomSummary`, `TimelineItem`, `RoomReadInputs` …). No upstream type, no `Any`, no JSON strings except where a raw format is the domain concept (e.g. `ImagePackContent` parsing input).
2. Streams are `AsyncStream<…>` of either **snapshots** (latest value wins) or **diffs** (ordered, lossless), and the doc comment says which.
3. Every throwing method throws `HaloError`.
4. Ports are coarse-grained, by use case (not one method per upstream function).
5. Every port has an in-memory fake in `HaloTestSupport`, and contract tests that run against both the fake and the real adapter (dev Synapse).

## 2. Port catalogue (MVP)

| Port | Purpose | Key operations (sketch) | Implemented by |
|---|---|---|---|
| `SessionPort` | Auth & session | `loginDetails(server:)`, `loginPassword(_:on:)`, `restore(_:)`, `logout()`, `sessionUpdates() -> AsyncStream<SessionEvent>` (lossless) — **in code since M0**; `oauthURL`, `completeOAuth(callback)` added in M5 (MINOR) | Adapter |
| `SyncPort` | Sync lifecycle | `start()` (idempotent), `stop()` (idempotent), `statuses() -> AsyncStream<SyncStatus>` (snapshot; `idle/running/offline/failed/stopped`) — **in code since M1**; only `SyncCoordinator` calls it, room list and timeline never start sync | Adapter |
| `RoomListPort` | Room list | `rooms(filter:) -> AsyncStream<RoomListDiff>` (lossless; every subscription starts from a known state), `loadMore()`, `setFilter(_:)` — **in code since M0**; `RoomListDiff` mirrors upstream `RoomListEntriesUpdate` | Adapter |
| `RoomReadStatePort` | Inputs for read state | `updates() -> AsyncStream<RoomReadInputsPart>` (lossless; one full per-room snapshot per change, coalesced by the consumer per room id), `allInputs() async -> [RoomReadInputsPart]` (initial load and reconcile), `ownReceipt(room)` | Adapter |
| `ReadMarkerPort` | Outbound read state | `sendReceipt(room, event, private:)`, `setFullyRead(room, event)`, `markRoomRead(room, private:) -> EventRef`, `setMarkedUnread(room, Bool)`, `markAllRead()` | Adapter |
| `TimelinePort` | Timeline of one room | `open(room) -> TimelineSession`; `TimelineSession.items() -> AsyncStream<TimelineDiff>` (lossless diffs), `paginateBackwards(count) -> Bool`, `close()` — **read-only part in code since M1**; `send(text:)` (Markdown → message content by the SDK, local echo as `SendState.sending` → `.sent`/`.failed`) — **in code since M2 start**; `toggleReaction(on:key:)`, `edit(event:newText:)`, `delete(event:)` on confirmed events (event ID, not the local echo) — **in code**; `reply(to:text:)` quoting the original via `ReplyPreview` — **in code**; `sendImage`, `sendRawMessage(type, contentJSON)` follow | Adapter |
| `MediaPort` | Media | `thumbnail(ref, width, height)`, `content(ref)` — **in code since M1** (`MediaRef` is an opaque token only the adapter can read); `file(ref) -> URL`, `upload(data, mime)` follow in M2 | Adapter |
| `RoomPort` | Room management | `details(room)`, `members(room)`, `leave`, `invite`, `createDM(user)`, `createRoom(opts)`, `setNotificationMode`, `state(room, type)`, `sendState(room, type, key, json)` | Adapter |
| `ProfilePort` | Profiles | `ownProfile`, `setDisplayName`, `setAvatar`, `profile(user)`, `ignore(user)` | Adapter |
| `AccountDataPort` | Account data | `get(type) -> JSON?`, `set(type, JSON)`, `observe(type)` | Adapter |
| `EncryptionPort` | E2EE & devices | `statuses() -> AsyncStream<EncryptionStatus>` (verification + recovery state, snapshot), `recover(recoveryKey:)`, `enableRecovery() -> key` — **in code since M1**; `startVerification`, `backupState`, `devices` follow | Adapter |
| `NotificationFetchPort` | NSE | `notification(room, event) -> FetchedNotification` | Adapter |
| `PusherPort` | Pushers | `register(token, gateway)`, `unregister()` | Adapter |
| `ReadIntentStore`, `NotificationRecordStore`, `AuditStore`, `StickerPackCache`, `BotTaskStore` | Halo persistence | CRUD with monotonic guards (sticker favourites/recents are account data via `AccountDataPort`, not a store) | HaloPersistence |
| `SystemNotificationsPort`, `BadgePort`, `KeychainPort` (**in code since M0**: `read`/`write`/`delete` of a `KeychainItem`), `BackgroundTaskPort` | OS | deliver/remove notifications, set badge, secrets, BG scheduling | HaloPlatform |

Exact signatures are written in code in M0–M1 and must match the intent of this table; any deviation updates this document.
Ports live in `ios/Packages/HaloDomain/Sources/HaloDomain/Ports/` and use typed throws (`throws(HaloError)`), so the compiler enforces
rule 3. Fakes and the contract suites (`SessionPortContract`, `RoomListPortContract`, `TimelinePortContract`, `SyncPortContract`, `MediaPortContract`, `EncryptionPortContract`) are in `HaloTestSupport`.

**Verified against the dev Synapse (M1 slice):** a freshly synced room holds only its newest event, so a timeline consumer must back-paginate; `paginateBackwards` returns `false` until one call past the last page, and the SDK puts a `timelineStart` virtual item on top when the start is loaded (the coordinator treats that item as authoritative). Room list and timeline diffs share one `ListDiff`/`ListReducer`.

## 3. Mapping responsibilities (adapter)
- Upstream `RoomInfo` → `RoomReadInputsPart` and `RoomSummary`. `RoomReadInputsPart` is the adapter's share of `RoomReadInputs`
  ([UNREAD_STATE.md](UNREAD_STATE.md) §4): every field except `localIntent` and `unconfirmedNotified`, which `ReadStateCoordinator`
  adds from HaloPersistence. It carries the per-room `sequence`.
- **One source per room.** All read-state fields of a room come from that room's `RoomInfo` (via `subscribe_to_room_info_updates`
  for every room in the room list, or the room-list entries if those carry the same `RoomInfo` — chosen in M1 by V-RS-1). The
  adapter never mixes the two sources for one room, and the `sequence` increases with every `RoomInfo` it maps.
- `LatestEventValue` → `LatestEventRef` (timestamp, is_own) (F-FFI-15).
- `TimelineDiff` → `TimelineDiff` (Halo) with `TimelineItem` values; unique stable ids from upstream unique ids.
- `ClientError` → `HaloError`.

## 4. Versioning the contract
- The ports have a `PortsVersion` constant (semantic: `MAJOR.MINOR`). A breaking change to any port → MAJOR, an addition → MINOR.
- A port change needs: an updated table above, updated fakes, updated contract tests, and a changelog line in `docs/matrix/PORTS_CHANGELOG.md` (created with the first change).
- SDK bumps must not change ports unless a feature needs it (then a MINOR, as a separate commit).
