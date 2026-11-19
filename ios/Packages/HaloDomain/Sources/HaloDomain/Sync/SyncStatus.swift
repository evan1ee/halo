/// The state of the sync loop (docs/matrix/SYNC_ENGINE.md §1). Mirrors upstream `SyncServiceState` one to one.
public enum SyncStatus: Sendable, Equatable {
    /// Not started.
    case idle
    case running
    /// The network is unreachable; the service waits and resumes by itself.
    case offline
    /// The loop stopped on an error; `SyncCoordinator` restarts it with backoff.
    case failed
    /// Stopped for good (after `stop()`).
    case stopped
}
