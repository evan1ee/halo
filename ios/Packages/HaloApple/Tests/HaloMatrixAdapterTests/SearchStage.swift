import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPersistence
import HaloTestSupport
import MatrixRustSDK
import Synchronization
import Testing
@testable import HaloMatrixAdapter

/// Message search as the app wires it: the live and history lanes, the index store and the search over it.
final class SearchStage: Sendable {
    let session: MatrixSessionPort
    let directory: URL
    let store: SearchIndexStore
    let source: MatrixMessageIndexSource
    let rooms: RoomListCoordinator
    let indexer: SearchIndexer
    let search: LocalMessageSearch
    let paused: PausedBox

    final class PausedBox: Sendable { let value: Mutex<Bool>; init(_ value: Bool) { self.value = Mutex(value) } }

    /// - Parameters:
    ///   - slow: waits between slices, so a test can stop in the middle; `rests: false` doesn't wait at all.
    ///   - joined: the joined rooms, instead of a room list of its own.
    init(
        _ session: MatrixSessionPort, directory: URL? = nil, paused: Bool = false, clockAhead: TimeInterval = 0, slow: Bool = false, rests: Bool = true,
        joined: (@Sendable () async -> [RoomID])? = nil
    ) throws {
        self.session = session
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("halo-search-\(UUID().uuidString)")
        self.directory = directory
        let store = SearchIndexStore(directory: directory, cipher: try FieldCipher(keyData: Data(repeating: 1, count: 32)))
        self.store = store
        let source = MatrixMessageIndexSource(session: session)
        self.source = source
        let rooms = RoomListCoordinator(port: MatrixRoomListPort(session: session), loadsAllPages: true)
        self.rooms = rooms
        let box = PausedBox(paused)
        self.paused = box
        let joined = joined ?? { await rooms.rooms.filter { $0.membership == .joined }.map(\.id) }
        indexer = SearchIndexer(
            index: store, source: source, rooms: joined,
            conditions: { SearchIndexPolicy.Conditions(pausedByUser: box.value.withLock { $0 }) },
            sleep: { try await Task.sleep(for: $0 == SearchIndexer.settleDelay ? .milliseconds(500) : slow ? .seconds(5) : rests ? min($0, .seconds(2)) : $0 >= SearchIndexer.busyInterval ? $0 : .zero) })
        search = LocalMessageSearch(
            index: store, source: source, joined: { Set(await joined()) }, ignored: { [] },
            now: { Date().addingTimeInterval(clockAhead) })
    }

    /// Listens, then syncs, as the app does.
    func start() async throws {
        await indexer.begin()
        await rooms.start()
        let changes = await rooms.summaryChanges()
        let indexer = indexer
        Task {
            var known: Set<RoomID> = []
            for await list in changes {
                let joined = Set(list.filter { $0.membership == .joined }.map(\.id))
                if joined != known {
                    known = joined
                    await indexer.roomsChanged()
                }
            }
        }
        try await session.startSync()
    }

    /// As when the app is killed: nothing is told to finish.
    func kill() async {
        await session.stopSync()
        await indexer.stop()
        await rooms.stop()
    }

    func bodies(_ query: String) async throws -> [String] { try await hits(query).map(\.body) }

    func hits(_ query: String) async throws -> [MessageSearchHit] {
        var result: [MessageSearchHit] = [], cursor: SearchCursor?
        repeat {
            let page = try await search.search(SearchQuery(text: query), after: cursor)
            result += page.hits
            cursor = page.next
        } while cursor != nil
        return result
    }

    func settle(_ seconds: Double = 60, _ what: String = "history to be read") async throws {
        try await Self.wait(seconds, what) { await self.indexer.status.phase == .done }
    }

    static func wait(_ seconds: Double, _ what: String, _ done: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try await !done() {
            guard ContinuousClock.now < deadline else { throw ContractViolation("\(what): not within \(seconds) s") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Plain calls to the Client-Server API as `session`'s user.
struct SearchServer {
    let session: MatrixSessionPort

    @discardableResult
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let sdk = try await session.signedInClient().session()
        let base = sdk.homeserverUrl.hasSuffix("/") ? sdk.homeserverUrl : sdk.homeserverUrl + "/"
        guard let url = URL(string: base + "_matrix/client/v3/" + path) else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + sdk.accessToken, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContractViolation("\(method) \(path.prefix(12)): \(String(decoding: data.prefix(120), as: UTF8.self))") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func makeRoom(encrypted: Bool = false, keyEvery messages: Int = 10) async throws -> RoomID {
        var body: [String: Any] = ["preset": "private_chat"]
        if encrypted {
            body["initial_state"] = [["type": "m.room.encryption", "state_key": "", "content": ["algorithm": "m.megolm.v1.aes-sha2", "rotation_period_msgs": messages]]]
        }
        return try RoomID(try await call("POST", "createRoom", body)["room_id"] as? String ?? "")
    }

    @discardableResult
    func send(_ text: String, to room: RoomID, extra: [String: Any] = [:]) async throws -> EventID {
        let body = ["msgtype": "m.text", "body": text].merging(extra) { $1 } as [String: Any]
        return try EventID(try await call("PUT", "rooms/\(room.rawValue)/send/m.room.message/\(UUID().uuidString)", body)["event_id"] as? String ?? "")
    }

    func edit(_ event: EventID, to text: String, in room: RoomID) async throws {
        try await send("* " + text, to: room, extra: ["m.new_content": ["msgtype": "m.text", "body": text], "m.relates_to": ["rel_type": "m.replace", "event_id": event.rawValue]])
    }

    func delete(_ event: EventID, in room: RoomID) async throws {
        try await call("PUT", "rooms/\(room.rawValue)/redact/\(event.rawValue)/\(UUID().uuidString)", [:])
    }
}
