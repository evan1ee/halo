# Concurrency Model

## 1. Language settings
- **[DECISION]** Swift 6 language mode with strict concurrency checking in every package. Zero
  warnings; `@unchecked Sendable` and `nonisolated(unsafe)` need a comment explaining why they're safe and a reviewer's sign-off.

## 2. Isolation

| Code | Isolation |
|---|---|
| Views, `@Observable` view models | `@MainActor` |
| Coordinators in `HaloApplication` | `actor` (one per coordinator), or `@MainActor` when they only feed UI |
| `HaloMatrixAdapter` services | `actor`s wrapping FFI objects; upstream objects are confined to the adapter actor that owns them |
| `HaloDomain` policies | Pure `Sendable` structs/functions; no isolation needed |
| `HaloPersistence` | GRDB `DatabasePool` (thread-safe); repository methods are `async` |

## 3. Rust async runtime and FFI callbacks
- **[VERIFIED F-FFI-2]** matrix-sdk-ffi runs its own tokio runtime; UniFFI exposes Rust `async fn`s as Swift `async` functions. Halo creates **no** runtime.
- FFI listener callbacks (e.g. `TimelineListener.on_update`) arrive on a **Rust thread**. Each adapter listener must:
  1. copy or map the payload into Swift value types right away (no upstream object kept outside the adapter);
  2. `yield` it into an `AsyncStream.Continuation` (thread-safe), with `bufferingPolicy` set per stream (see below);
  3. never block, never call back into the FFI synchronously.
- Buffering: timeline and room-list diffs use `.unbounded` (diffs must not be dropped, since they're incremental). `.bufferingNewest(1)`
  is allowed **only** for a stream that carries one logical value (sync state, one room's info). A stream that carries snapshots for
  many keys (e.g. read-state inputs for all rooms) is lossless (`.unbounded`), and the consumer coalesces per key (keeps the newest
  `sequence` per room id); dropping across keys would lose another room's update and cause a missed unread (R-P0-2).

## 4. Cancellation and lifetimes
- Upstream subscriptions return a `TaskHandle` **[VERIFIED F-FFI-4]**. The adapter wraps each in a Swift
  type that calls `cancel()` on `deinit` and when its `AsyncStream` ends (`onTermination`).
- Coordinators run long-lived work in `Task`s stored in the coordinator and cancelled on sign-out/deinit.
  No fire-and-forget `Task {}` except where a comment explains why.
- View models start their subscriptions in `.task {}` (bound to the view's lifetime).

## 5. Ordering guarantees
- Within one stream, order is kept. Across streams there is **no** ordering guarantee, so the read-state policy
  is written to be **order-independent** (property P3 in [../testing/UNREAD_REGRESSION_TESTS.md](../testing/UNREAD_REGRESSION_TESTS.md)).
- Each `RoomSnapshot` carries an adapter-assigned, increasing `sequence`; a coordinator ignores older snapshots.

## 6. Cross-process concurrency (app ⇄ NSE)
- SDK stores: the upstream cross-process lock (`CrossProcessLockConfig.MultiProcess`) **[VERIFIED F-FFI-10]**.
- `halo.sqlite`: GRDB `DatabasePool` in WAL mode, every write in a short `IMMEDIATE` transaction;
  writes are *upserts with monotonic guards* (e.g. a read intent only moves forward), so the outcome
  doesn't depend on which process writes first. **[ASSUMPTION V-SQL-2]**: GRDB's documented multi-process
  setup works for an app and an extension sharing a file.
- After writing, the NSE posts a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) so a running app reloads its state.

## 7. Forbidden patterns
`DispatchQueue.main.sync`; semaphores to wait on async work; `Task.detached` without a justification;
holding an upstream FFI object in a view model; blocking an FFI callback thread; shared mutable singletons.
