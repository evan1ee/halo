import HaloDomain
import HaloFoundation

/// One bounded catch-up while the app is in the background (a silent push, or iOS's app refresh; BACKGROUND_EXECUTION):
/// session → room list → one sync → evaluation written. Returns only when the new counts have reached the badge and the
/// widgets, because iOS suspends the app as soon as the work is reported as done.
public struct BackgroundRefresh: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let session: SessionCoordinator
    private let sync: SyncCoordinator
    private let rooms: RoomListCoordinator
    private let readState: ReadStateCoordinator
    private let sleep: Sleep

    /// iOS allows about 30 s; restoring and loading the list normally take well under one.
    public static let preparationLimit: Duration = .seconds(12)
    public static let evaluationLimit: Duration = .seconds(8)

    public init(
        session: SessionCoordinator, sync: SyncCoordinator, rooms: RoomListCoordinator, readState: ReadStateCoordinator,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.sync = sync
        self.rooms = rooms
        self.readState = readState
        self.sleep = sleep
    }

    /// `true` when a sync succeeded and its result is on the icon.
    public func run() async -> Bool {
        guard await prepared() else { return false }
        let epoch = await readState.syncEpoch
        guard await sync.syncOnceInBackground() else { return false }
        return await readState.waitForSync(after: epoch, timeout: Self.evaluationLimit)
    }

    /// The session is restored and the room list follows sync responses (it subscribes before it first loads).
    private func prepared() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [session, rooms] in
                for await state in await session.states() {
                    switch state {
                    case .launching, .restoring: continue
                    case .ready: break
                    default: return false
                    }
                    break
                }
                for await status in await rooms.statuses() {
                    if case .loaded = status { return true }
                    if case .failed = status { return false }
                }
                return false
            }
            group.addTask { [sleep] in
                try? await sleep(Self.preparationLimit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
