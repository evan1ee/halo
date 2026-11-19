# matrix-rust-sdk Integration

Decisions: D44, ADR-0002. All API names below are **[VERIFIED]** at rev `7ff8855` unless labelled otherwise
(see [../SOURCES.md](../SOURCES.md) F-FFI-1…22).

## 1. How the SDK is consumed

| Phase | Source | Why |
|---|---|---|
| M0 → G-FFI | Swift package `element-hq/matrix-rust-components-swift`, pinned by **exact version + checksum** (currently `26.11.17`) **[VERIFIED F-LIC-4, SOURCES pinned refs]** | No Rust toolchain needed; Apache-2.0; the upstream FFI unmodified |
| Before the first external TestFlight | Build the same FFI **from source at a pinned rev** with `cargo xtask swift build-framework` **[VERIFIED F-FFI-2]** (reproducible, auditable, our own feature selection) | Supply-chain control; licence inventory matches what we ship ([OPEN Q-SDK-BUILD]: decide the exact timing) |
| If G-FFI fails | Halo-owned crate `core/halo-ffi` over `matrix-sdk` + `matrix-sdk-ui` | ADR-0003 |

**Version mapping.** The prebuilt package version is date-based; record the matching upstream SDK commit
in `ios/SDKVERSION.md` (planned for M0) at each bump **[OPEN V-SDK-1: confirm how prebuilt releases map to SDK commits]**.

## 2. Ownership and lifecycle

| Object | Owner (Swift) | Created | Dropped |
|---|---|---|---|
| Platform/tracing init | `HaloMatrixAdapter.Bootstrap` | First call in each process: `init_platform(...)` (F-FFI-13) | Never (process-wide) |
| `ClientBuilder` → `Client` | `MatrixClientService` (actor) | Login or restore | Logout / sign-out |
| `SyncService` | `MatrixSyncService` | After the client is ready: `client.sync_service()` → builder → `finish()` | Logout |
| `RoomListService`, `RoomList` | `MatrixRoomListService` | `sync_service.room_list_service()`, `.all_rooms()` | With `SyncService` |
| `Room` handles | Adapter caches by id | `client.get_room(id)` | Room left / memory pressure |
| `Timeline` | `MatrixTimelineService` per open room | `room.timeline()` / `timeline_with_configuration(...)` | When the screen closes |
| `NotificationClient` | NSE pipeline | `client.notification_client(NotificationProcessSetup.MultipleProcesses)` | After each push |
| `TaskHandle`s | Wrapped in `SubscriptionToken` | Each `add_listener` / `subscribe_*` | `deinit` / stream end → `cancel()` |

## 3. Client initialisation
`ClientBuilder()` → `.server_name_or_homeserver_url(...)` → `.session_paths(dataPath, cachePath)` (App Group
container; `data` and `caches` subfolders) → `.sqlite_store(SqliteStoreBuilder(dataPath, cachePath).passphrase(<from Keychain>))` **[VERIFIED F-FFI-17]** →
`.sliding_sync_version_builder(.discoverNative)` (fails clearly on servers without native sliding sync; `.native` once
discovery is confirmed) **[VERIFIED F-FFI-17]** →
`.cross_process_lock_config(.multiProcess(holderName: "app"|"nse"))` → `.set_session_delegate(...)` (token
refresh persistence) → `.build()`.

## 4. Authentication and session restoration
- Discovery: `client.homeserver_login_details()` → supports OIDC? password?
- OIDC: `url_for_oauth(...)` → `ASWebAuthenticationSession` → `login_with_oauth_callback(url)`.
- Password: `login(username, password, initialDeviceName, deviceId)`.
- Persist `client.session()` in the Keychain (access group shared with the NSE); token refreshes arrive via the session delegate and are persisted at once.
- Restore: `restore_session(session)` (or `restore_session_with`). Failure with an auth error → soft logout flow.
Detailed flows: [../features/AUTHENTICATION.md](../features/AUTHENTICATION.md).

## 5. Sync
See [SYNC_ENGINE.md](SYNC_ENGINE.md).

## 6. Rooms and timelines
- Room list: `RoomList.entries_with_dynamic_adapters(pageSize, listener)` → `RoomListEntriesUpdate` diffs + a
  `RoomListDynamicEntriesController` (`set_filter`, `add_one_page`). The adapter turns diffs into
  `[RoomSummary]` updates (values).
- Room info: `room.subscribe_to_room_info_updates(listener)` → `RoomInfo` → `RoomReadInputs` (unread fields F-FFI-7).
- Timeline: `timeline.add_listener(listener)` → `[TimelineDiff]` → domain `TimelineItem` diffs;
  `paginate_backwards(n)`; `subscribe_to_back_pagination_status`.
- Sending: `send`, `send_reply`, `edit`, `redact_event`, `toggle_reaction`, `send_image`; local echo and
  retry via the timeline and the send queue (`client.enable_all_send_queues`, `room.subscribe_to_send_queue_updates`).
- Stickers: `room.send_raw("m.sticker", json)` (F-FFI-9). Rendering: `MsgLikeKind.Sticker{body, info, source}` (F-FFI-8).

## 7. Read state
[READ_RECEIPTS.md](READ_RECEIPTS.md) and [UNREAD_STATE.md](UNREAD_STATE.md).

## 8. Media
[MEDIA.md](MEDIA.md).

## 9. Error propagation
Every FFI call can throw `ClientError` (and specific errors such as `RoomListError`). The adapter maps them in
`ErrorMapper` → `HaloError` ([../architecture/ERROR_HANDLING.md](../architecture/ERROR_HANDLING.md)).

## 10. API compatibility policy
- Bumps at most monthly, on a branch, following [../development/BUILD_AND_RELEASE.md](../development/BUILD_AND_RELEASE.md) §3.
- Compile errors are allowed **only** inside `HaloMatrixAdapter`. If a bump needs a port change, that is a
  versioned contract change ([PORTS_CONTRACT.md](PORTS_CONTRACT.md) §4).
- The adapter's contract tests run against the dev Synapse on every bump.
