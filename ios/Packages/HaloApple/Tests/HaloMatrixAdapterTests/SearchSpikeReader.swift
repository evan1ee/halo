import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization
@testable import HaloMatrixAdapter

/// How Halo's own search index would read messages (M17-8, ADR-0024): decrypted events through SDK timelines. Test code only.
struct SearchSpikeReader {
    let room: @Sendable (RoomID) async throws -> Room
    let own: String
    static let plain = TimelineConfiguration(
        focus: .live(hideThreadedEvents: false), filter: .all, internalIdPrefix: "search", dateDividerMode: .monthly, trackReadReceipts: .disabled, reportUtds: false)

    init(session: MatrixSessionPort) async throws {
        own = try await session.ownUserID()
        room = { try await session.room($0) }
    }

    init(client: Client) throws {
        own = try client.userId()
        room = { id in
            guard let room = try client.getRoom(roomId: id.rawValue) else { throw HaloError.notFound }
            return room
        }
    }

    struct Slice {
        var events: [HaloDomain.TimelineEvent] = []
        var reachedStart = false
        var pages = 0

        var messages: [HaloDomain.TimelineEvent] { events.filter { $0.kind.isSearchable } }
        var undecryptable: [HaloDomain.TimelineEvent] {
            events.filter { if case .undecryptable = $0.kind { true } else { false } }
        }
        /// The oldest event that isn't in a thread would be needed here; the fixtures have no threads.
        var oldest: EventID? { events.first { $0.eventID != nil }?.eventID }
    }

    /// What the SDK holds for `room` now, read back page by page until `known` contains an event or `maxPages` is reached.
    func recent(_ room: RoomID, known: Set<EventID> = [], maxPages: Int = 0, waitForKeys seconds: Double = 0) async throws -> Slice {
        try await read(room, focus: .live(hideThreadedEvents: false), pageSize: 50, waitForKeys: seconds) { slice in
            slice.pages >= maxPages || slice.events.contains { $0.eventID.map(known.contains) ?? false }
        }
    }

    /// `pages` pages of history before `event`, from an event-focused timeline that is dropped afterwards.
    func history(_ room: RoomID, before event: EventID, pages: Int, pageSize: UInt16 = 100, waitForKeys seconds: Double = 0) async throws -> Slice {
        let focus = TimelineFocus.event(eventId: event.rawValue, numContextEvents: 0, threadMode: .automatic(hideThreadedEvents: false))
        return try await read(room, focus: focus, pageSize: pageSize, waitForKeys: seconds) { $0.pages >= pages }
    }

    private func read(_ id: RoomID, focus: TimelineFocus, pageSize: UInt16, waitForKeys seconds: Double = 0, done: (Slice) -> Bool) async throws -> Slice {
        let room = try await room(id)
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: focus, filter: .all, internalIdPrefix: "search", dateDividerMode: .monthly, trackReadReceipts: .disabled, reportUtds: false))
        let mirror = SpikeMirror(own: own)
        let handle = await timeline.addListener(listener: mirror)
        defer { handle.cancel() }
        await mirror.settle(after: 0)  // the first update carries what is there
        var slice = Slice()
        slice.events = mirror.events
        while !done(slice), !slice.reachedStart {
            let seen = mirror.updates
            slice.reachedStart = try await timeline.paginateBackwards(numEvents: pageSize)
            await mirror.settle(after: seen)
            slice.events = mirror.events
            slice.pages += 1
        }
        // Keys are fetched after a failed decryption and change the item later: waits until none is left or nothing changed for five seconds.
        let deadline = ContinuousClock.now + .seconds(seconds)
        var changed = ContinuousClock.now, left = slice.undecryptable.count
        while left > 0, ContinuousClock.now < deadline, ContinuousClock.now - changed < .seconds(5) {
            try await Task.sleep(for: .milliseconds(100))
            slice.events = mirror.events
            if slice.undecryptable.count != left { left = slice.undecryptable.count; changed = .now }
        }
        return slice
    }
}

extension TimelineEventKind {
    var isSearchable: Bool {
        switch self {
        case .text, .notice, .emote, .media, .poll: true
        default: false
        }
    }
}

/// The timeline's items, kept from its updates as the app keeps them.
final class SpikeMirror: TimelineListener {
    private let own: String
    private let state = Mutex((items: [HaloDomain.TimelineItem](), updates: 0))

    static let alive = Mutex(0)

    init(own: String) {
        self.own = own
        Self.alive.withLock { $0 += 1 }
    }

    deinit { Self.alive.withLock { $0 -= 1 } }

    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) {
        let mapped = diff.map { TimelineMapper.map($0, ownUserID: own) }
        state.withLock { state in
            for diff in mapped { try? ListReducer.apply(diff, to: &state.items) }
            state.updates += 1
        }
    }

    var updates: Int { state.withLock { $0.updates } }
    var events: [HaloDomain.TimelineEvent] {
        state.withLock { $0.items.compactMap { if case .event(let event) = $0.content { event } else { nil } } }
    }

    /// Updates arrive on another thread a moment after the call that caused them: waits for one, then until 10 ms pass without another.
    func settle(after count: Int) async {
        for _ in 0..<300 where updates <= count { try? await Task.sleep(for: .milliseconds(1)) }
        var last = updates
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            if updates == last { return }
            last = updates
        }
    }
}

/// A client of its own for the history lane: the same account, keys and state store as the app's, an event cache of its own, one room loaded,
/// no sync and no send queue. The SDK never drops an event-focused cache (F-FFI-26); dropping this client does.
enum SearchSpikeHistoryClient {
    static func make(_ stored: StoredSession, directory: URL, caches: URL, room: RoomID?) async throws -> Client {
        let payload = try JSONDecoder().decode(MatrixSessionPort.SessionPayload.self, from: stored.payload)
        let data = directory.appendingPathComponent(payload.storeID, isDirectory: true).appendingPathComponent("data")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let delegate = RefreshDelegate(storeID: payload.storeID, passphrase: payload.passphrase, readStoredSession: { stored }, onRefresh: { _ in })
        let client = try await ClientBuilder()
            .homeserverUrl(url: payload.homeserverURL)
            .sessionPaths(dataPath: data.path, cachePath: caches.path)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: data.path, cachePath: caches.path).passphrase(passphrase: payload.passphrase))
            .slidingSyncVersionBuilder(versionBuilder: .none)
            .autoEnableBackups(autoEnableBackups: true)
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: "search"))
            .setSessionDelegate(sessionDelegate: delegate)
            .build()
        let session = Session(
            accessToken: payload.accessToken, refreshToken: payload.refreshToken, userId: payload.userID, deviceId: payload.deviceID,
            homeserverUrl: payload.homeserverURL, oauthData: payload.oauthData, slidingSyncVersion: .none)
        if let room { try await client.restoreSessionWith(session: session, roomLoadSettings: .one(roomId: room.rawValue)) } else { try await client.restoreSession(session: session) }
        return client
    }
}

/// The live lane without timelines: what sync brings into a room, decrypted, from the SDK's per-room event listener. Events that couldn't be
/// decrypted arrive as `m.room.encrypted`.
final class SearchSpikeListener: RoomMessageLikeEventsListener {
    struct Seen { var messages: [String: [String]] = [:]; var encrypted: [String: [String]] = [:]; var redactions = 0 }
    private let room: String
    private let seen: SearchSpikeSeen

    init(room: String, seen: SearchSpikeSeen) {
        self.room = room
        self.seen = seen
    }

    func onEvent(event: RoomMessageLikeEvent) {
        let room = room
        seen.value.withLock { seen in
            switch event.eventType {
            case .roomMessage: seen.messages[room, default: []].append(event.eventId)
            case .roomEncrypted: seen.encrypted[room, default: []].append(event.eventId)
            default: seen.redactions += 1
            }
        }
    }

    static func subscribe(_ room: Room, seen: SearchSpikeSeen) -> [TaskHandle] {
        [.roomMessage, .roomEncrypted, .roomRedaction].map { type in
            room.subscribeToMessageLikeEvents(eventType: type, listener: SearchSpikeListener(room: room.id(), seen: seen))
        }
    }
}

final class SearchSpikeSeen: Sendable {
    let value = Mutex(SearchSpikeListener.Seen())
}
