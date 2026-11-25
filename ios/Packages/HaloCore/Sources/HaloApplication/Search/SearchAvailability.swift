import HaloDomain
import HaloFoundation
import Synchronization

/// The search of the signed-in account, which comes and goes with the session; without one, search says so.
public final class CurrentSearchPort: SearchPort {
    private let current = Mutex<(any SearchPort)?>(nil)
    public init() {}

    public func set(_ port: (any SearchPort)?) { current.withLock { $0 = port } }

    public func search(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage {
        guard let port = current.withLock({ $0 }) else { throw .storage(.unavailable) }
        return try await port.search(query, after: cursor)
    }
}

/// Holds the first sync of a session back until search listens, but never for long: what it misses is read from the server later.
public actor SearchStartGate {
    public static let patience: Duration = .milliseconds(1_500)

    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let sleep: SearchIndexer.Sleep

    public init(sleep: @escaping SearchIndexer.Sleep = { try await Task.sleep(for: $0) }) { self.sleep = sleep }

    public func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// The next session waits again.
    public func close() { isOpen = false }

    public func wait() async {
        guard !isOpen else { return }
        let timeout = Task { [sleep] in
            do { try await sleep(Self.patience) } catch { return }
            self.giveUp()
        }
        await withCheckedContinuation { waiting.append($0) }
        timeout.cancel()
    }

    private func giveUp() {
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
