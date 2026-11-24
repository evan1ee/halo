import HaloFoundation

/// Starts and stops the sync loop and reports its state (docs/matrix/PORTS_CONTRACT.md §2). Implemented by
/// `HaloMatrixAdapter` over `SyncService`; faked in `HaloTestSupport`. Only `SyncCoordinator` calls it:
/// room list and timeline never start sync themselves.
public protocol SyncPort: Sendable {
    /// Starts syncing. Idempotent: starting a running loop does nothing. Throws `.unauthorized` without a session.
    func start() async throws(HaloError)

    /// Stops syncing and waits until the loop has ended. Idempotent.
    func stop() async

    /// Runs a single bounded sync pass without starting the foreground long-poll loop (e.g. on a silent background push).
    func syncOnce() async throws(HaloError)

    /// The current status, then every change. Snapshot semantics: the latest value wins (CONCURRENCY §3).
    func statuses() -> AsyncStream<SyncStatus>
}
