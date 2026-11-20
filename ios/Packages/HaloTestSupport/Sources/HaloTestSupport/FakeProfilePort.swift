import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `ProfilePort`.
public final class FakeProfilePort: ProfilePort {
    private struct State {
        var ownName: String
        var profiles: [UserID: UserProfile]
        var ignored: [UserID]
        var error: HaloError?
    }
    private let state: Mutex<State>

    public init(ownName: String = "", profiles: [UserProfile] = [], ignored: [UserID] = []) {
        state = Mutex(State(ownName: ownName, profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.userID, $0) }), ignored: ignored))
    }

    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    public var storedOwnName: String { state.withLock { $0.ownName } }
    public var ignored: [UserID] { state.withLock { $0.ignored } }

    private func check() throws(HaloError) { if let error = state.withLock({ $0.error }) { throw error } }

    public func ownDisplayName() async throws(HaloError) -> String { try check(); return state.withLock { $0.ownName } }

    public func setOwnDisplayName(_ name: String) async throws(HaloError) { try check(); state.withLock { $0.ownName = name } }

    public func profile(of user: UserID) async throws(HaloError) -> UserProfile {
        try check()
        guard let profile = state.withLock({ $0.profiles[user] }) else { throw .notFound }
        return profile
    }

    public func ignoredUsers() async throws(HaloError) -> [UserID] { try check(); return state.withLock { $0.ignored } }

    public func ignore(_ user: UserID) async throws(HaloError) {
        try check()
        state.withLock { if !$0.ignored.contains(user) { $0.ignored.append(user) } }
    }

    public func unignore(_ user: UserID) async throws(HaloError) {
        try check()
        state.withLock { $0.ignored.removeAll { $0 == user } }
    }
}
