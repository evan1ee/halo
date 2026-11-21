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
in `ios/SDKVERSION.md` at each bump: the components repo's release commit names the SDK commit (V-SDK-1 resolved).

## 2. Ownership and lifecycle

| Object | Owner (Swift) | Created | Dropped |
|---|---|---|---|
| Platform/tracing init | `HaloMatrixAdapter.MatrixBootstrap` | First call in each process: `initPlatform(config:useLightweightTokioRuntime:)` (F-FFI-13, R-09) | Never (process-wide) |
| `ClientBuilder` → `Client` | `MatrixSessionPort` (actor) | Login or single-flight restore (R-12) | Logout / hard auth error (R-10) |
| Classic `/sync` loop | `MatrixSessionPort.runSync` / `MatrixSyncPort` | After the client is ready: `client.syncOnceV2(...)` (D74) | Background / logout / auth error |
| Room list projection | `MatrixRoomListPort` | Reads `client.rooms()` + `roomInfo()` per `SyncChange` (D74) | Logout |
| `Room` handles | Resolved on demand via `client.getRoom(roomId:)` | Per operation | ARC release |
| `Timeline` | `MatrixTimelinePort` (warm cache up to 6) | `room.timeline()` | Cache eviction / room close / logout |
| `NotificationClient` | `MatrixNotificationPort` (NSE) | `client.notificationClient(processSetup: .multipleProcesses)` | After each push |
| `TaskHandle`s | Owned by port actors / `SubscriptionToken` | `setDelegate`, `subscribeToSendQueueStatus`, `addListener`, etc. | Tear-down / stream end → `cancel()` |

## 3. Client initialisation
`ClientBuilder()` → `.serverNameOrHomeserverUrl(...)` → `.sessionPaths(dataPath, cachePath)` (App Group
container; `data` and `caches` subfolders) → `.sqliteStore(config: SqliteStoreBuilder(dataPath, cachePath).passphrase(passphrase:))` **[VERIFIED F-FFI-17]** →
`.slidingSyncVersionBuilder(versionBuilder: .none)` (classic sync since **[DECISION D74]**) →
`.autoEnableCrossSigning(autoEnableCrossSigning: true)` → `.autoEnableBackups(autoEnableBackups: true)` →
`.crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: "app"|"nse"))` →
`.setSessionDelegate(sessionDelegate:)` (token refresh persistence across app and NSE, R-11) → `.build()`.
After login/restore, `adopt` registers `Client.setDelegate` (`AuthDelegate`, R-10) so remote token revocation stops sync and emits `.loggedOut` / `.softLoggedOut`.

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
- Room list (D74): `MatrixRoomListPort` projects `client.rooms()` on each classic `/sync` response (`SyncChange`), emits `.reset` diffs of `[RoomSummary]` (carrying `RoomReadCounts` from `Room.roomInfo()`), `leftRooms()` for pruning (R-03), and `syncCompletions()` for ending carry-over (R-04).
- Timeline: `timeline.addListener(listener:)` → `[TimelineDiff]` → domain `TimelineItem` diffs;
  `paginateBackwards(numEvents:)`; `latestEventId()` (used by `TimelineReadTracker` at the tail row, R-06).
- Sending: `send`, `sendReply`, `edit`, `redactEvent`, `toggleReaction`, `sendImage`; local echo and
  retry via the timeline and the send queue (`client.enableAllSendQueues`, `client.subscribeToSendQueueStatus`).
- Stickers: `room.sendRaw("m.sticker", json)` (F-FFI-9; R-21 tracks moving to send queue if supported). Rendering: `MsgLikeKind.sticker(body:info:source:)` (F-FFI-8).

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
