import HaloDomain
import Synchronization

/// In-memory `PreferencesPort` fake for unit tests (TD-02).
public final class FakePreferencesPort: PreferencesPort, Sendable {
    private let state: Mutex<PreferencesSnapshot>

    public init(initial: PreferencesSnapshot = PreferencesSnapshot()) {
        state = Mutex(initial)
    }

    public func load() -> PreferencesSnapshot {
        state.withLock { $0 }
    }

    public func save(_ snapshot: PreferencesSnapshot) {
        state.withLock { $0 = snapshot }
    }
}
