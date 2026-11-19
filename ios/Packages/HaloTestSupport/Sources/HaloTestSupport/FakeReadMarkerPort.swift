import HaloDomain
import HaloFoundation
import Synchronization

/// Records receipts and markers; can be told to fail the next receipts.
public final class FakeReadMarkerPort: ReadMarkerPort {
    public struct Sent: Sendable, Equatable {
        public let room: RoomID
        public let event: EventID
        public let isPrivate: Bool

        public init(room: RoomID, event: EventID, isPrivate: Bool) {
            self.room = room
            self.event = event
            self.isPrivate = isPrivate
        }
    }

    private struct State {
        var receipts: [Sent] = []
        var markers: [Sent] = []
        var failures: [HaloError] = []
    }
    private let state = Mutex(State())

    public init() {}

    public var receipts: [Sent] { state.withLock { $0.receipts } }
    public var markers: [Sent] { state.withLock { $0.markers } }

    /// The next `sendReceipt` calls throw these errors in order (each consumed once).
    public func failNextReceipts(with errors: [HaloError]) { state.withLock { $0.failures = errors } }

    public func sendReceipt(room: RoomID, event: EventID, isPrivate: Bool) async throws(HaloError) {
        let failure: HaloError? = state.withLock { $0.failures.isEmpty ? nil : $0.failures.removeFirst() }
        if let failure { throw failure }
        state.withLock { $0.receipts.append(Sent(room: room, event: event, isPrivate: isPrivate)) }
    }

    public func setFullyRead(room: RoomID, event: EventID) async throws(HaloError) {
        state.withLock { $0.markers.append(Sent(room: room, event: event, isPrivate: false)) }
    }
}
