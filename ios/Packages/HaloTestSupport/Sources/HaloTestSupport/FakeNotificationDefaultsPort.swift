import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `NotificationDefaultsPort`: starts at "all messages" for direct chats and "mentions" for groups.
public final class FakeNotificationDefaultsPort: NotificationDefaultsPort {
    private struct State {
        var modes: [NotificationDefaultKind: RoomNotificationChoice] = [.directChats: .allMessages, .groupChats: .mentionsAndKeywords]
        var error: HaloError?
    }
    private let state = Mutex(State())

    public init() {}

    /// Makes every following call throw (nil: stop failing).
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }

    public func mode(for kind: NotificationDefaultKind) async throws(HaloError) -> RoomNotificationChoice {
        let (mode, error) = state.withLock { ($0.modes[kind] ?? .allMessages, $0.error) }
        if let error { throw error }
        return mode
    }

    public func setMode(_ mode: RoomNotificationChoice, for kind: NotificationDefaultKind) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.modes[kind] = mode }
    }
}
