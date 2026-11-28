import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// Message search of the signed-in account (MESSAGE_SEARCH, ADR-0024): the index, what fills it and what searches it come and go
/// with the session. The rules are in `SearchIndexer` and `SearchIndexPolicy`; this type owns their lifecycle (audit F-02: moved
/// out of the app target so it is unit-tested). Platform facts — the device's state, the phone's lock, the background task —
/// come in through `Environment` and the `phoneWillLock` / `phoneUnlocked` / `conditionsChanged` calls.
@MainActor
public final class MessageSearchEngine {
    /// What the device allows right now (Low Power Mode, heat, network); read each time the indexer asks.
    public struct DeviceState: Sendable, Equatable {
        public var lowPower: Bool
        public var isHot: Bool
        public var onMobileData: Bool
        public var offline: Bool

        public init(lowPower: Bool = false, isHot: Bool = false, onMobileData: Bool = false, offline: Bool = false) {
            self.lowPower = lowPower
            self.isHot = isHot
            self.onMobileData = onMobileData
            self.offline = offline
        }
    }

    /// The platform services the engine uses; the app supplies iOS's, tests their own.
    public struct Environment {
        public var device: @Sendable () -> DeviceState
        /// Asks iOS for a processing task (on the charger) to read the rest of the history.
        public var scheduleProcessing: @MainActor () -> Void
        /// Deletes every account's index files and any pending processing task (sign-out, AC-SRCH-8).
        public var removeAllIndexes: @MainActor () -> Void

        public init(
            device: @escaping @Sendable () -> DeviceState = { DeviceState() },
            scheduleProcessing: @escaping @MainActor () -> Void = {},
            removeAllIndexes: @escaping @MainActor () -> Void = {}
        ) {
            self.device = device
            self.scheduleProcessing = scheduleProcessing
            self.removeAllIndexes = removeAllIndexes
        }
    }

    /// Joined rooms and ignored senders kept in memory, so `LocalMessageSearch` makes no actor or FFI hop per keystroke.
    private final class FilterCache: Sendable {
        private struct Value {
            var joined: Set<RoomID> = []
            var ignored: Set<UserID> = []
        }
        private let state = Mutex(Value())

        var joined: Set<RoomID> { state.withLock { $0.joined } }
        var ignored: Set<UserID> { state.withLock { $0.ignored } }

        func setJoined(_ rooms: Set<RoomID>) { state.withLock { $0.joined = rooms } }
        func setIgnored(_ users: Set<UserID>) { state.withLock { $0.ignored = users } }
        func reset() { state.withLock { $0 = Value() } }
    }

    private final class IndexerBox: Sendable {
        private let state = Mutex<SearchIndexer?>(nil)
        var current: SearchIndexer? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    private final class RoomCoordinatorsBox: Sendable {
        private final class WeakRef {
            weak var coordinator: SearchCoordinator?
            init(_ coordinator: SearchCoordinator) { self.coordinator = coordinator }
        }
        private let refs = Mutex<[WeakRef]>([])

        func add(_ coordinator: SearchCoordinator) {
            refs.withLock { list in
                list.removeAll { $0.coordinator == nil }
                list.append(WeakRef(coordinator))
            }
        }

        func active() -> [SearchCoordinator] {
            refs.withLock { list in
                list.removeAll { $0.coordinator == nil }
                return list.compactMap(\.coordinator)
            }
        }
    }

    public let coordinator: SearchCoordinator
    /// Holds the first sync back until search listens.
    public let gate = SearchStartGate()
    /// The newest status of the index, for the results and Settings.
    public private(set) var status = SearchIndexStatus()
    /// Whether an account's index is attached.
    public var isAttached: Bool { account != nil }

    private let port = CurrentSearchPort()
    private let filterCache = FilterCache()
    private let indexerBox = IndexerBox()
    private let roomCoordinators = RoomCoordinatorsBox()
    private let source: any MessageIndexSourcePort
    private let rooms: RoomListCoordinator
    private let profiles: any ProfilePort
    private let encryption: EncryptionCoordinator
    private let preferences: PreferencesStore
    private let environment: Environment
    private let log: HaloLog?
    private var account: UserID?
    private var store: (any AccountSearchIndexPort)?
    private var indexer: SearchIndexer? {
        didSet { indexerBox.current = indexer }
    }
    private var following: [Task<Void, Never>] = []
    private var isForeground = false
    private var isProcessing = false
    private var listeners: [AsyncStream<SearchIndexStatus>.Continuation] = []

    public init(
        source: any MessageIndexSourcePort, rooms: RoomListCoordinator, profiles: any ProfilePort, encryption: EncryptionCoordinator,
        preferences: PreferencesStore, environment: Environment = Environment(), log: HaloLog? = nil
    ) {
        self.source = source
        self.rooms = rooms
        self.profiles = profiles
        self.encryption = encryption
        self.preferences = preferences
        self.environment = environment
        self.log = log
        let indexerBox = indexerBox
        coordinator = SearchCoordinator(
            port: port,
            onRemoteQuery: { query in await indexerBox.current?.setActiveQuery(query) })
    }

    // MARK: Session

    /// Opens `user`'s index (made by `makeIndex`, only when the account changes) and begins to listen. Before the session's first sync.
    public func attach(_ user: UserID, index makeIndex: @MainActor () -> any AccountSearchIndexPort) async {
        guard account != user else { return await gate.open() }
        await detach(deletingIndex: false)
        account = user
        let store = makeIndex()
        await store.resume()  // pre-warms the file so the very first search keystroke never pays for opening it
        let rooms = rooms, profiles = profiles, filterCache = filterCache
        let initialRooms = Set(await rooms.rooms.filter { $0.membership == .joined }.map(\.id))
        if !initialRooms.isEmpty {
            filterCache.setJoined(initialRooms)
        } else if let known = await source.joinedRooms() {
            filterCache.setJoined(known)
        }
        let joined: @Sendable () async -> [RoomID] = {
            let loaded = await rooms.rooms.filter { $0.membership == .joined }.map(\.id)
            if !loaded.isEmpty { return loaded }
            return Array(filterCache.joined)
        }
        let coordinator = self.coordinator, roomCoordinators = self.roomCoordinators
        let indexer = SearchIndexer(
            index: store, source: source, rooms: joined,
            conditions: { [weak self] in await self?.conditions() ?? SearchIndexPolicy.Conditions(mayRun: false) }, log: log,
            onWrite: { changedRooms in
                await coordinator.refresh(in: changedRooms)
                for roomCoordinator in roomCoordinators.active() {
                    await roomCoordinator.refresh(in: changedRooms)
                }
            })
        self.store = store
        self.indexer = indexer
        port.set(LocalMessageSearch(
            index: store, source: source, joined: { filterCache.joined }, ignored: { filterCache.ignored }))
        await indexer.begin()
        await gate.open()
        let statuses = await indexer.statuses(), lists = await rooms.summaryChanges(), keys = await encryption.snapshots()
        following = [
            Task {
                if let ignored = try? await profiles.ignoredUsers() {  // best-effort: falls back to empty until next sync/ignore refresh
                    filterCache.setIgnored(Set(ignored))
                }
            },
            Task { [weak self] in
                for await status in statuses { self?.publish(status) }
            },
            Task {
                var known: Set<RoomID> = []
                for await list in lists {
                    let joinedSet = Set(list.lazy.filter { $0.membership == .joined }.map(\.id))
                    if !joinedSet.isEmpty || !known.isEmpty {
                        filterCache.setJoined(joinedSet)
                    }
                    guard joinedSet != known else { continue }
                    known = joinedSet
                    await indexer.roomsChanged()
                }
            },
            Task {
                // A connected key backup makes older encrypted messages readable.
                var before: EncryptionStatus?
                for await snapshot in keys {
                    let status = snapshot.status
                    if let before, before.recovery != .enabled, status.recovery == .enabled { await indexer.keysArrived() }
                    if let before, before.verification != .verified, status.verification == .verified { await indexer.keysArrived() }
                    before = status
                }
            },
        ]
    }

    /// Refreshes the cached ignored-user set after an ignore/unignore action and updates any open search results immediately.
    public func refreshIgnoredUsers() async {
        let ignored = (try? await profiles.ignoredUsers()) ?? []  // best-effort: keeps none ignored on read failure
        filterCache.setIgnored(Set(ignored))
        await coordinator.refresh()
        for roomCoordinator in roomCoordinators.active() {
            await roomCoordinator.refresh()
        }
    }

    /// Creates an independent `SearchCoordinator` for in-room search (M20-11), backed by the account's live index and
    /// active-query history prioritisation without disturbing global chat-list search.
    public func makeRoomSearchCoordinator() -> SearchCoordinator {
        let indexerBox = indexerBox
        let roomCoordinator = SearchCoordinator(
            port: port,
            onRemoteQuery: { query in await indexerBox.current?.setActiveQuery(query) })
        roomCoordinators.add(roomCoordinator)
        return roomCoordinator
    }

    /// Current on-device indexing coverage for a single room (M20-11); `nil` if not yet scanned or detached.
    public func roomCoverage(for room: RoomID) async -> RoomSearchCoverage? {
        guard let store else { return nil }
        return (try? await store.coverage())?[room]  // best-effort: unread coverage treats room as still indexing
    }

    /// Stops reading and lets go of the second SDK client; before the session's stores are deleted.
    public func stop() async {
        port.set(nil)
        await indexer?.stop()
    }

    /// The account signed out (or another one signs in): with `deletingIndex`, nothing of its index stays on the device (AC-SRCH-8).
    public func detach(deletingIndex: Bool) async {
        for task in following { task.cancel() }
        following = []
        await stop()
        filterCache.reset()
        indexer = nil
        account = nil
        await gate.close()
        await coordinator.clear()
        for roomCoordinator in roomCoordinators.active() {
            await roomCoordinator.clear()
        }
        publish(SearchIndexStatus())
        if deletingIndex {
            store?.destroy()
            environment.removeAllIndexes()
        }
        store = nil
    }

    // MARK: When history may be read

    public func setForeground(_ active: Bool) async {
        guard active != isForeground else { return }
        isForeground = active
        await indexer?.conditionsChanged()
        if !active, !status.isComplete, account != nil, !preferences.searchHistoryPaused { environment.scheduleProcessing() }
    }

    /// The person is doing something: reading history waits a moment.
    public func noteActivity() { Task { await indexer?.noteActivity() } }

    /// The device's state or the user's search settings changed.
    public func conditionsChanged() { Task { await indexer?.conditionsChanged() } }

    /// A processing task on the charger; `true` when there is more to read.
    public func process() async -> Bool {
        guard let indexer else { return false }
        isProcessing = true
        defer { isProcessing = false }
        await indexer.runInBackground()
        return !status.isComplete
    }

    /// What the indexer may do now (SearchIndexPolicy).
    func conditions() -> SearchIndexPolicy.Conditions {
        let device = environment.device()
        return SearchIndexPolicy.Conditions(
            pausedByUser: preferences.searchHistoryPaused, lowPower: device.lowPower, isHot: device.isHot, onMobileData: device.onMobileData,
            mobileDataAllowed: preferences.searchHistoryOnMobileData, offline: device.offline, mayRun: isForeground || isProcessing)
    }

    /// The phone is about to lock: the index file closes (D124).
    public func phoneWillLock() async {
        let joined = await rooms.rooms.filter { $0.membership == .joined }.map(\.id)
        await store?.suspend(rooms: joined)
    }

    /// The phone was unlocked: the index file opens again and reading may go on.
    public func phoneUnlocked() async {
        await store?.resume()
        await indexer?.conditionsChanged()
    }

    // MARK: Status

    public func statuses() -> AsyncStream<SearchIndexStatus> {
        let (stream, continuation) = AsyncStream<SearchIndexStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(status)
        listeners.append(continuation)
        return stream
    }

    private func publish(_ new: SearchIndexStatus) {
        status = new
        listeners.removeAll { continuation in
            if case .terminated = continuation.yield(new) { return true }
            return false
        }
    }

    /// Deletes and rebuilds the index (Settings → Message search); `false` when it couldn't.
    public func rebuild() async -> Bool {
        guard let indexer else { return false }
        return (try? await indexer.rebuild()) != nil  // best-effort: a failed rebuild is reported as false
    }
}
