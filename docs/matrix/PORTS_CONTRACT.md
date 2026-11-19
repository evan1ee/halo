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
| `SessionPort` | Auth & session | `loginDetails(server)`, `loginPassword`, `oauthURL`, `completeOAuth(callback)`, `restore(session)`, `logout()`, `sessionUpdates: AsyncStream<SessionEvent>` | Adapter |
| `SyncPort` | Sync lifecycle | `start()`, `stop()`, `status: AsyncStream<SyncStatus>` (snapshot) | Adapter |
| `RoomListPort` | Room list | `rooms(filter:) -> AsyncStream<RoomListDiff>`, `loadMore()`, `setFilter(_)` | Adapter |
| `RoomReadStatePort` | Inputs for read state | `updates() -> AsyncStream<RoomReadInputsPart>` (lossless; one full per-room snapshot per change, coalesced by the consumer per room id), `allInputs() async -> [RoomReadInputsPart]` (initial load and reconcile), `ownReceipt(room)` | Adapter |
| `ReadMarkerPort` | Outbound read state | `sendReceipt(room, event, private:)`, `setFullyRead(room, event)`, `markRoomRead(room, private:) -> EventRef`, `setMarkedUnread(room, Bool)`, `markAllRead()` | Adapter |
| `TimelinePort` | Timeline of one room | `open(room) -> TimelineSession`; `TimelineSession.items: AsyncStream<TimelineDiff>`, `paginateBackwards(n)`, `send(_ draft)`, `reply`, `edit`, `redact`, `toggleReaction`, `sendImage`, `sendRawMessage(type, contentJSON)` | Adapter |
| `MediaPort` | Media | `thumbnail(source, size)`, `content(source)`, `file(source) -> URL`, `upload(data, mime)` | Adapter |
| `RoomPort` | Room management | `details(room)`, `members(room)`, `leave`, `invite`, `createDM(user)`, `createRoom(opts)`, `setNotificationMode`, `state(room, type)`, `sendState(room, type, key, json)` | Adapter |
| `ProfilePort` | Profiles | `ownProfile`, `setDisplayName`, `setAvatar`, `profile(user)`, `ignore(user)` | Adapter |
| `AccountDataPort` | Account data | `get(type) -> JSON?`, `set(type, JSON)`, `observe(type)` | Adapter |
| `EncryptionPort` | E2EE & devices | `verificationState`, `startVerification`, `recover(recoveryKey)`, `backupState`, `devices` | Adapter |
| `NotificationFetchPort` | NSE | `notification(room, event) -> FetchedNotification` | Adapter |
| `PusherPort` | Pushers | `register(token, gateway)`, `unregister()` | Adapter |
| `ReadIntentStore`, `NotificationRecordStore`, `AuditStore`, `StickerPrefsCache`, `BotTaskStore` | Halo persistence | CRUD with monotonic guards | HaloPersistence |
| `SystemNotificationsPort`, `BadgePort`, `KeychainPort`, `BackgroundTaskPort` | OS | deliver/remove notifications, set badge, secrets, BG scheduling | HaloPlatform |

Exact signatures are written in code in M0–M1 and must match the intent of this table; any deviation updates this document.

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
