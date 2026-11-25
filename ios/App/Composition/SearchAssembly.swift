import FeatureSearch
import FeatureSettings
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import UIKit

/// Message search of the signed-in account (MESSAGE_SEARCH, ADR-0024): the index, what fills it and what searches it come and go with the
/// session. Wiring only; the rules are in `SearchIndexer` and `SearchIndexPolicy`.
@MainActor
final class MessageSearchEngine {
    let coordinator: SearchCoordinator
    /// Holds the first sync back until search listens.
    let gate = SearchStartGate()

    private let port = CurrentSearchPort()
    private let source: MatrixMessageIndexSource
    private let rooms: RoomListCoordinator
    private let profiles: MatrixProfilePort
    private let encryption: EncryptionCoordinator
    private let preferences: PreferencesStore
    private let log: HaloLog
    private var account: UserID?
    private var store: SearchIndexStore?
    private var indexer: SearchIndexer?
    private var following: [Task<Void, Never>] = []
    private var isForeground = false
    private var isProcessing = false
    private var status = SearchIndexStatus()
    private var listeners: [AsyncStream<SearchIndexStatus>.Continuation] = []
    private var device: DeviceConditions?
    private var protected: ProtectedData?

    init(session: MatrixSessionPort, rooms: RoomListCoordinator, profiles: MatrixProfilePort, encryption: EncryptionCoordinator, preferences: PreferencesStore, log: HaloLog) {
        source = MatrixMessageIndexSource(session: session)
        coordinator = SearchCoordinator(port: port)
        self.rooms = rooms
        self.profiles = profiles
        self.encryption = encryption
        self.preferences = preferences
        self.log = log
        device = DeviceConditions { [weak self] in Task { await self?.indexer?.conditionsChanged() } }
        protected = ProtectedData(
            willLock: { [weak self] in Task { @MainActor in await self?.phoneWillLock() } },
            didUnlock: { [weak self] in Task { @MainActor in await self?.phoneUnlocked() } })
    }

    // MARK: Session

    /// Opens the account's index and begins to listen. Before the session's first sync.
    func attach(_ user: UserID, cipher: FieldCipher?) async {
        guard account != user else { return await gate.open() }
        await detach(deletingIndex: false)
        account = user
        let protected = protected
        let store = SearchIndexStore(directory: HaloShared.searchDirectory(for: user), cipher: cipher, isReadable: { protected?.isReadable ?? true })
        let rooms = rooms, profiles = profiles
        let joined: @Sendable () async -> [RoomID] = { await rooms.rooms.filter { $0.membership == .joined }.map(\.id) }
        let indexer = SearchIndexer(
            index: store, source: source, rooms: joined,
            conditions: { [weak self] in await self?.conditions() ?? SearchIndexPolicy.Conditions(mayRun: false) }, log: log)
        self.store = store
        self.indexer = indexer
        port.set(LocalMessageSearch(
            index: store, source: source, joined: { Set(await joined()) }, ignored: { Set((try? await profiles.ignoredUsers()) ?? []) }))
        await indexer.begin()
        await gate.open()
        let statuses = await indexer.statuses(), lists = await rooms.summaryChanges(), keys = await encryption.snapshots()
        following = [
            Task { [weak self] in
                for await status in statuses { self?.publish(status) }
            },
            Task {
                var known: Set<RoomID> = []
                for await list in lists {
                    let joined = Set(list.lazy.filter { $0.membership == .joined }.map(\.id))
                    guard joined != known else { continue }
                    known = joined
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

    /// Stops reading and lets go of the second SDK client; before the session's stores are deleted.
    func stop() async {
        port.set(nil)
        await indexer?.stop()
    }

    /// The account signed out (or another one signs in): nothing of its index stays on the device (AC-SRCH-8).
    func detach(deletingIndex: Bool) async {
        for task in following { task.cancel() }
        following = []
        await stop()
        indexer = nil
        account = nil
        await gate.close()
        await coordinator.clear()
        publish(SearchIndexStatus())
        if deletingIndex {
            store?.destroy()
            SearchIndexStore.removeAll(in: HaloShared.searchDirectory())
            SearchProcessingTask.cancel()
        }
        store = nil
    }

    // MARK: When history may be read

    func setForeground(_ active: Bool) async {
        guard active != isForeground else { return }
        isForeground = active
        await indexer?.conditionsChanged()
        if !active, !status.isComplete, account != nil, !preferences.searchHistoryPaused { SearchProcessingTask.schedule(log: log) }
    }

    /// The person is doing something: reading history waits a moment.
    func noteActivity() { Task { await indexer?.noteActivity() } }

    func conditionsChanged() { Task { await indexer?.conditionsChanged() } }

    /// A processing task on the charger; `true` when there is more to read.
    func process() async -> Bool {
        guard let indexer else { return false }
        isProcessing = true
        defer { isProcessing = false }
        await indexer.runInBackground()
        return !status.isComplete
    }

    private func conditions() -> SearchIndexPolicy.Conditions {
        let device = device?.snapshot ?? .init()
        return SearchIndexPolicy.Conditions(
            pausedByUser: preferences.searchHistoryPaused, lowPower: device.lowPower, isHot: device.isHot, onMobileData: device.onMobileData,
            mobileDataAllowed: preferences.searchHistoryOnMobileData, offline: device.offline, mayRun: isForeground || isProcessing)
    }

    private func phoneWillLock() async {
        let joined = await rooms.rooms.filter { $0.membership == .joined }.map(\.id)
        await store?.suspend(rooms: joined)
    }

    private func phoneUnlocked() async {
        await store?.resume()
        await indexer?.conditionsChanged()
    }

    // MARK: Status and settings

    func statuses() -> AsyncStream<SearchIndexStatus> {
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

    /// Settings → Message search.
    func settingsStatus() -> SearchIndexSettingsActions.Status? {
        guard account != nil else { return nil }
        let chats = "\(status.completeRooms) of \(status.totalRooms) chats"
        let progress: String = switch status.phase {
        case .done: status.isComplete ? "Complete" : chats
        case .indexing: "Reading · \(chats)"
        case .paused(.busy): "Reading · \(chats)"
        case .paused: "Paused · \(chats)"
        case .unavailable: "Not available now"
        case .stopped: "Starting"
        }
        return .init(progress: progress, size: StorageSize(name: "Search index (\(status.statistics.messages.formatted()) messages)", bytes: status.statistics.bytes))
    }

    func rebuild() async -> Bool {
        guard let indexer else { return false }
        return (try? await indexer.rebuild()) != nil
    }
}

extension AppRoot {
    /// Message search view model for the `.searchable` room list (D85).
    func makeMessageSearch() -> MessageSearchViewModel {
        MessageSearchViewModel(
            coordinator: search.coordinator,
            roomName: { [roomList] room in
                if case .loaded(_, let rows) = roomList.content, let row = rows.first(where: { $0.id == room }) { return row.name }
                return "Room"
            },
            statuses: { [search] in await search.statuses() },
            needsVerification: { [recovery] in recovery.needsRecovery },
            onActivity: { [search] in search.noteActivity() })
    }
}
