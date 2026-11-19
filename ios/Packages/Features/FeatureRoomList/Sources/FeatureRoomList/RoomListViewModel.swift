import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The room list for the signed-in user. M0 shows the count and the room names, which is the
/// milestone's exit signal (docs/ROADMAP.md M0); rows, filters and unread badges arrive in M1.
///
/// It follows the session: the list is subscribed while a session is ready and stopped otherwise.
@MainActor @Observable
public final class RoomListViewModel {
    public enum Content: Equatable {
        case idle
        case loading
        case loaded(count: Int, names: [String])
        case failed(String)
    }

    public private(set) var content: Content = .idle

    private let session: SessionCoordinator
    private let rooms: RoomListCoordinator
    private var tasks: [Task<Void, Never>] = []

    public init(session: SessionCoordinator, rooms: RoomListCoordinator) {
        self.session = session
        self.rooms = rooms
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
            let names = await rooms.rooms.map { $0.name ?? "Unnamed room" }
            content = .loaded(count: count, names: names)
        case .failed: content = .failed("The room list couldn't be loaded. Pull to try again.")
        }
    }
}
