import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `DraftPort`; can be told to fail.
public final class FakeDrafts: DraftPort {
    private struct State {
        var drafts: [RoomID: String] = [:]
        var failing = false
    }
    private let state = Mutex(State())

    public init(_ initial: [RoomID: String] = [:]) { state.withLock { $0.drafts = initial } }

    public var stored: [RoomID: String] { state.withLock { $0.drafts } }
    public func setFailing(_ value: Bool) { state.withLock { $0.failing = value } }

    public func draft(for room: RoomID) async throws(HaloError) -> String? {
        let (failing, text) = state.withLock { ($0.failing, $0.drafts[room]) }
        if failing { throw .storage(.corrupted) }
        return text
    }

    public func save(_ text: String, for room: RoomID) async throws(HaloError) {
        let failing = state.withLock { $0.failing }
        if failing { throw .storage(.corrupted) }
        state.withLock { state in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.drafts[room] = nil } else { state.drafts[room] = text }
        }
    }
}
