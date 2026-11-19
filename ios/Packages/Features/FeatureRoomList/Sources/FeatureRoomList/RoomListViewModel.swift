import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The room list for the signed-in user. It shows the count and the room names (M0's exit signal); a row selects a room for the timeline. Filters and unread
/// badges come with the read-state work (M3).
///
/// It follows the session: the list is subscribed while a session is ready and stopped otherwise.
@MainActor @Observable
public final class RoomListViewModel {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: RoomID
        public let name: String
    }

    public enum Content: Equatable {
        case idle
        case loading
        case loaded(count: Int, rows: [Row])
        case failed(String)
    }

    public private(set) var content: Content = .idle

    private let session: SessionCoordinator
    private let rooms: RoomListCoordinator
    private let receipts: ReadReceiptCoordinator?
    private var tasks: [Task<Void, Never>] = []

    /// Set when a swipe action fails; the view shows it and the next successful action clears it.
    public private(set) var actionError: String?

    public init(session: SessionCoordinator, rooms: RoomListCoordinator, receipts: ReadReceiptCoordinator? = nil) {
        self.session = session
        self.rooms = rooms
        self.receipts = receipts
    }

    /// "Mark as read" (swipe, ROOM_LIST FR-6).
    public func markRead(_ room: RoomID) async {
        guard let receipts else { return }
        let latest = await rooms.rooms.first { $0.id == room }?.latestEvent?.timestamp
        await perform { () async throws(HaloError) in try await receipts.markRoomRead(room, latestEventTime: latest) }
    }

    /// "Mark as unread" (swipe, ROOM_LIST FR-6).
    public func markUnread(_ room: RoomID) async {
        guard let receipts else { return }
        await perform { () async throws(HaloError) in try await receipts.markRoomUnread(room) }
    }

    private func perform(_ action: () async throws(HaloError) -> Void) async {
        do { try await action(); actionError = nil } catch { actionError = "That didn't work. Try again." }
    }

    isolated deinit { tasks.forEach { $0.cancel() } }

    /// Starts following the session and the list. Call once when the screen appears.
    public func start() async {
        guard tasks.isEmpty else { return }
        let sessionStates = await session.states()
        let listStatuses = await rooms.statuses()
        tasks = [
            Task { [weak self] in
                for await state in sessionStates { await self?.sessionChanged(state) }
            },
            Task { [weak self] in
                for await status in listStatuses { await self?.listChanged(status) }
            },
        ]
    }

    func sessionChanged(_ state: SessionCoordinator.State) async {
        if case .ready = state { await rooms.start() } else { await rooms.stop() }
    }

    func listChanged(_ status: RoomListCoordinator.Status) async {
        switch status {
        case .idle: content = .idle
        case .loading: content = .loading
        case .loaded(let count):
            let rows = await rooms.rooms.map { Row(id: $0.id, name: $0.name ?? "Unnamed room") }
            content = .loaded(count: count, rows: rows)
        case .failed: content = .failed("The room list couldn't be loaded. Pull to try again.")
        }
    }
}
