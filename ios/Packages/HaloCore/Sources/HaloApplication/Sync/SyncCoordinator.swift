import HaloDomain
import HaloFoundation

/// Owns the sync loop (docs/matrix/SYNC_ENGINE.md §2): it runs while a session is ready and the app is in
/// the foreground, and restarts with backoff after a failure. Nothing else starts or stops sync.
public actor SyncCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Restart delays after consecutive failures: 1 s, 2 s, 4 s … capped at 60 s (SYNC_ENGINE §1).
    public static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(60, 1 << min(max(failures - 1, 0), 6)))
    }

    public private(set) var status: SyncStatus = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any SyncPort
    private let session: SessionCoordinator
    private let sleep: Sleep
    private var broadcaster = SnapshotBroadcaster<SyncStatus>()
    private var isForeground = false
    private var isSessionReady = false
    private var applied = false
    private var isReconciling = false
    private var failures = 0
    private var observers: [Task<Void, Never>] = []
    private var restart: Task<Void, Never>?

    public init(port: any SyncPort, session: SessionCoordinator, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.session = session
        self.sleep = sleep
    }

    deinit {
        observers.forEach { $0.cancel() }
        restart?.cancel()
    }

    public func statuses() -> AsyncStream<SyncStatus> { broadcaster.subscribe(current: status) }

    /// Starts following the session and the port. Call once at launch.
    public func begin() async {
        guard observers.isEmpty else { return }
        let sessionStates = await session.states()
        let portStatuses = port.statuses()
        observers = [
            Task { [weak self] in
                for await state in sessionStates {
                    var ready = false
                    if case .ready = state { ready = true }
                    await self?.setSessionReady(ready)
                }
            },
            Task { [weak self] in
                for await status in portStatuses { await self?.portReported(status) }
            },
        ]
    }

    /// The scene phase: `true` for `.active`, `false` for `.inactive`/`.background` (SYNC_ENGINE §2 rule 1).
    public func setForeground(_ foreground: Bool) async {
        isForeground = foreground
        await reconcile()
    }

    /// Runs a single bounded sync pass in the background (e.g. when woken by a silent push, ADR-0015 / D112)
    /// without starting the foreground long-poll loop. Returns `true` when the sync succeeded; does nothing while the
    /// foreground loop runs (it delivers the same changes).
    @discardableResult
    public func syncOnceInBackground() async -> Bool {
        // Asked directly: after a cold background launch the session can be ready before this actor has heard about it.
        guard case .ready = await session.state, !applied else { return false }
        do {
            try await port.syncOnce()
            return true
        } catch {
            return false
        }
    }

    // MARK: Private

    private func setSessionReady(_ ready: Bool) async {
        isSessionReady = ready
        await reconcile()
    }

    private func portReported(_ reported: SyncStatus) async {
        status = reported
        switch reported {
        case .running:
            failures = 0
            restart?.cancel()
        case .failed:
            if shouldRun { scheduleRestart() }
        default: break
        }
    }

    private var shouldRun: Bool { isForeground && isSessionReady }

    private func reconcile() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        while shouldRun != applied {
            let target = shouldRun
            if target {
                restart?.cancel()
                do { try await port.start() } catch {
                    status = .failed
                    if error.isRetryable { scheduleRestart() }
                    // A non-retryable error (e.g. no session) is not retried; the next session or phase change tries again.
                    return
                }
            } else {
                restart?.cancel()
                await port.stop()
                failures = 0
            }
            applied = target
        }
    }

    private func scheduleRestart() {
        restart?.cancel()
        failures += 1
        let delay = Self.backoff(afterFailures: failures)
        restart = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            await self?.retry()
        }
    }

    private func retry() async {
        guard shouldRun else { return }
        applied = false
        await reconcile()
    }
}
