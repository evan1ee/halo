# Halo — Technical Architecture

Status: v0.1. Decisions: D3, D8, D9, D19, D27, D30, D40–D42.

## 1. System context

```
             ┌─────────────────────────── your infrastructure ───────────────────────────┐
             │  Synapse (native sliding sync)  ──push──▶  Sygnal  ──APNs──▶  Apple       │
             │  MAS (OIDC)           matrix-bot (unchanged, normal Matrix user)          │
             └──────────────▲──────────────────────────────────────────────────▲─────────┘
                            │ HTTPS (CS API, sliding sync)                     │ APNs
┌───────────────────────────┴──────────────────── iPhone ─────────────────────┴─────────┐
│  Halo.app (SwiftUI)                              HaloNSE (Notification Service Ext.)   │
│     │                                               │                                  │
│     └──────────── HaloCore.xcframework (Rust, one static lib) ─────────────┘           │
│                    ├─ matrix-sdk-ffi (upstream, pinned, unmodified)                    │
│                    └─ halo-* crates (unread, store, stickers, later search)            │
│                 App Group container: SDK stores + halo.sqlite (encrypted)              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

## 2. Why the Rust SDK (and not a native Swift Matrix implementation)

- E2EE (Olm/Megolm via vodozemac, cross-signing, key backup, verification) is the hardest part
  of any Matrix client to get right and keep secure. Writing it again in Swift is out of scope for one person working part-time.
- `matrix-sdk-ui` already provides the room list service, timeline (local echo, edits, reactions,
  read markers), sync service, notification client (used by the NSE) and send queue.
- Licence: Apache-2.0 throughout, verified for the whole iOS dependency tree (doc 03).
- The cost: an unstable FFI API, a heavy binary (~40–60 MB static lib before stripping), a Rust toolchain.
  We accept it.

Alternatives rejected: the older Objective-C/Swift SDK `matrix-ios-sdk` (deprecated, no sliding sync);
Trixnity/Kotlin Multiplatform (not mature on iOS); writing our own SDK (years of work).

## 3. Rust core (`/core`)

```
core/
  Cargo.toml                (workspace; pins matrix-rust-sdk git rev)
  halo-ffi/                 crate-type = ["staticlib", "lib"]; UniFFI proc-macros
                            depends on matrix-sdk-ffi (lib), halo-unread, halo-store, halo-stickers
  halo-unread/              pure engine, no I/O, no SDK types in its public API (own types)
  halo-store/               rusqlite + SQLCipher; migrations; App Group path; cross-process lock
  halo-stickers/            MSC2545 pack model, merge of user and room packs, favourites and recents
  halo-search/   (P1)       only if upstream search_service is insufficient (evaluate first)
  halo-testkit/             fixtures, Synapse scenario harness client, sync replay
```

- **One static library, two sets of bindings.** UniFFI's "library mode" generates Swift for every
  UniFFI crate linked into the library. Swift code sees `MatrixSDKFFI` types (Client, RoomListService,
  Timeline, NotificationClient, SyncService, Encryption …) and `HaloFFI` types (UnreadEngine,
  StickerService, HaloStore).
- `halo-ffi` gets SDK objects from the upstream FFI `Client` (e.g. the inner `matrix_sdk::Client`
  through Rust-side access in the same crate graph). It does **not** expose them to Swift a second time.
- Upgrades: bump the pinned rev on a branch, build, and fix the Swift compile errors. Upgrade monthly at most, and
  only for fixes or features we need.

### 3.1 SDK ownership and lifecycle

- One `HaloSession` (Swift actor) per signed-in account owns: the `Client`, `SyncService`,
  `RoomListService`, the `UnreadEngine` handle and the `StickerService`.
- Lifecycle: `launch → restore session → start SyncService → observe` / `background → stop sync
  (after finishing the receipt outbox) → suspend` / `foreground → start → reconcile`.
- The NSE builds a **separate, lightweight** client (`NotificationClient`, process setup for the NSE) from the same
  session files. It never runs the full sync. Cross-process safety: the SDK's cross-process store
  lock for crypto data, plus `halo-store`'s own lock for writes to `halo.sqlite` (see doc 05 §6).
- NSE memory limit (~24 MB historically; measure on iOS 26): keep the NSE build lean, avoid loading
  timelines, and measure from milestone M1 onwards (risk T2).

## 4. Swift application (`/ios`)

```
ios/
  Halo.xcodeproj            app target, NSE target, share extension (later)
  Packages/
    HaloKit/                service protocols + live implementations over HaloCore
                            (SessionService, RoomListService, TimelineService, ComposerService,
                             MediaService, UnreadService, StickerService, PushService)
    HaloUI/                 design system: colours, typography, components, Markdown/HTML renderer
    Features/
      Auth/  RoomList/  Timeline/  Composer/  Stickers/  RoomInfo/  Settings/
      BotRendering/         BotMessageRenderer (D19): pure Swift, independent of HaloCore types
    HaloTestSupport/        fakes for every service protocol, snapshot helpers
```

### 4.1 State and data flow

- `@Observable` view models, one per screen or feature, `@MainActor` (D41).
- Services wrap the FFI and turn listener callbacks into `AsyncStream`s of **Swift value types**.
  FFI types never reach views.
- Flow: `Rust SDK → FFI listener → service (actor, maps to value types, coalesces) → AsyncStream →
  view model (main actor) → SwiftUI`.
- Timeline: apply SDK `TimelineDiff` batches to an identity-stable array; render with a
  `List`/`ScrollView` tuned for reverse-chronological layout; coalesce updates to at most one per frame.
- Dependency injection: constructor injection in view models; a `ServiceContainer` passed through the
  SwiftUI `Environment` at the root; fakes in previews and tests. No DI framework.

### 4.2 Concurrency

- Swift 6 strict concurrency. Services are actors; FFI callbacks hop onto the service actor.
- Rust: the tokio runtime owned by matrix-sdk-ffi's runtime setup; halo crates use the same runtime
  (exposed through `halo-ffi`). No blocking calls on the main thread; all FFI calls are `async`.

### 4.3 BotMessageRenderer (D19–D23)

```
BotMessageRenderer
  input:  BotMessageInput { senderId, eventId, roomId, body, formattedBody?, ts, relations }
  pipeline:
    1. sender in allowlist? else → GenericRenderer
    2. TemplateParser registry (versioned, strict): TodoListParserV1, TaskAddedParserV1,
       ReminderSetParserV1 … each returns ParsedCard or nil
    3. ParsedCard → native SwiftUI card; nil → GenericRenderer (HTML subset → AttributedString)
  always: "View source" shows the original body/formatted_body
  interactions: BotActionCoordinator (reaction-based protocol, D22/D23)
```
- Fixtures come from the bot repository's test strings (MIT; attribution in acknowledgements).
- `BotActionCoordinator` keeps a pending state machine per (room, entity):
  `idle → pending(reactionTxnId) → confirmed | failed(retryable)`. It moves to confirmed **only** when an authoritative
  bot event arrives (acknowledgement reaction or reply from the bot sender, or an updated list showing the item done).
- The task→event index (room, bot sender, entity id → event id) is derived from timeline events
  and kept in `halo-store` (P1). Redactions and edits update the index.

## 5. Persistence (D40)

| Store | Owner | Contents |
|---|---|---|
| SDK state/crypto/event-cache stores | matrix-sdk (SQLite) | sessions, keys, room state, cached events |
| `halo.sqlite` (SQLCipher) | halo-store | unread engine snapshots + receipt outbox, sticker favourites/recents cache, bot task index, search index (P1), media index (P1), auditor logs |
| Keychain (shared access group) | Swift | session secrets, DB passphrase |
| UserDefaults (App Group) | Swift | UI preferences only |

- Files use `NSFileProtectionCompleteUntilFirstUserAuthentication` so the NSE can work while the phone is locked after the first unlock.
- Migrations: a numbered SQL list in `halo-store`, applied in a transaction inside the cross-process lock;
  every migration is tested from every earlier schema in Linux CI. `halo.sqlite` is a **cache plus outbox**:
  if it is corrupted we rebuild it from the SDK stores and the server; data is lost only for what hasn't been sent (the outbox).

## 6. Sync

- `SyncService` (sliding sync, MSC4186) with the room list service. Enable the **receipts,
  account_data and typing extensions** for the room-list subscription. This matters for unread state: without the receipts extension, receipts for rooms that aren't open can be missed (doc 05 §5).
- Foreground: continuous. Background: BGAppRefreshTask (short sync and reconcile) plus
  background pushes (best effort). There is no persistent background connection on iOS.
- Offline: the SDK send queue keeps outgoing messages; our receipt outbox keeps receipts.

## 7. Notification architecture (summary; details in doc 05)

- Pusher registered with `event_id_only` format and `default_payload` with `mutable-content: 1`.
- Sygnal → APNs (token-based auth key). NSE: fetch the event, decrypt, evaluate push rules locally, update
  the unread engine, recompute the badge, build the content (communication notification with an avatar).
- Filtering entitlement: suppress notifications that shouldn't show; without it, show a generic text.

## 8. Error handling and recovery

- Errors are typed at the service boundary: `.network(retryable)`, `.auth(expired)`, `.crypto(utd)`,
  `.server(code)`, `.internal`. UI shows inline, recoverable states; nothing fails silently.
- Session expiry or soft logout → a re-auth flow that keeps the stores.
- Sync failures → exponential backoff; `SyncService` state shown as an "offline" banner.
- Crash reporting: none to third parties by default (privacy). Local logs are exportable in the diagnostic bundle.

## 9. Testing (summary; see doc 06)

- Rust: unit tests, property tests (`halo-unread`), Synapse scenario tests (Docker), sync replay.
- Swift: view-model tests with fake services; BotMessageRenderer fixture tests; snapshot tests for cards;
  a small XCUITest smoke suite against the dev Synapse, run locally.

## 10. Future-proofing

- Calls: `matrix-sdk-ffi` exposes a widget driver; Element Call is embedded as a widget (MatrixRTC). Keep
  the audio-session and CallKit code out of the MVP, but don't take over `AVAudioSession` anywhere else.
- Multi-account: `HaloSession` per account; the store is keyed by user id from day one (cheap now, expensive to add later).
