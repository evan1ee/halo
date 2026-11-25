import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// Halo's adapter and the SDK behind a broken network (ROADMAP M17-6): a throwaway Synapse behind infra/test's fault proxy. Run with
/// `infra/test/run.sh faults`; skipped otherwise. A `FAULT` line per test says how long recovery took.
private let env = ProcessInfo.processInfo.environment

@Suite("Faults", .serialized, .cleansUp, .enabled(if: env["HALO_FAULT_CONTROL"] != nil, "needs infra/test/run.sh faults"))
struct FaultTests {
    @Test("The server goes away for five seconds: sync says so, comes back by itself and delivers what was missed", .timeLimit(.minutes(3)))
    func outage() async throws {
        let stage = try await Stage()
        try await stage.proxy.fault(["action": "refuse"])
        try await stage.wait(60, "sync reports the outage") { [.offline, .failed].contains(stage.sync.last) }
        try await stage.peer.send("missed", to: stage.room)
        try await Task.sleep(for: .seconds(5))
        let back = ContinuousClock.now
        try await stage.proxy.heal()
        try await stage.wait(60, "the missed message") { stage.mirror.shows("missed") }
        stage.report("outage", since: back)
    }

    @Test("A half-open connection: the hung sync is given up and the message still arrives", .timeLimit(.minutes(4)))
    func halfOpenSync() async throws {
        let stage = try await Stage()
        try await stage.proxy.fault(["action": "hang", "path": "/sync", "times": 1])
        try await stage.wait(30, "a sync request hangs") { try await stage.proxy.hits() == 1 }
        try await stage.peer.send("behind the hang", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(120, "the message") { stage.mirror.shows("behind the hang") }
        stage.report("halfOpenSync", since: start)
    }

    @Test("A sync response that breaks off is fetched again; nothing is lost", .timeLimit(.minutes(3)))
    func cutSync() async throws {
        let stage = try await Stage()
        try await stage.proxy.fault(["action": "cut", "bytes": 40, "path": "/sync", "times": 1])
        // The poll already under way isn't affected: the message must go into the response that breaks off.
        try await stage.wait(30, "the next sync") { try await stage.proxy.hits() == 1 }
        try await stage.peer.send("cut off", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(60, "the message") { stage.mirror.shows("cut off") }
        stage.report("cutSync", since: start)
    }

    @Test("Server errors on sync are retried", .timeLimit(.minutes(3)))
    func syncServerErrors() async throws {
        let stage = try await Stage()
        try await stage.proxy.fault(["action": "status", "status": 502, "path": "/sync", "times": 3])
        try await stage.wait(30, "the next sync") { try await stage.proxy.hits() >= 1 }
        try await stage.peer.send("after 502", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(60, "the message") { stage.mirror.shows("after 502") }
        stage.report("syncServerErrors", since: start)
    }

    @Test("A send is delivered exactly once", .timeLimit(.minutes(3)), arguments: [
        Broken(name: "lost answer", rule: ["action": "lose", "path": "/send/", "times": 1]),
        Broken(name: "rate limited twice", rule: ["action": "status", "status": 429, "retry_after_ms": 600, "path": "/send/", "times": 2]),
        Broken(name: "server error twice", rule: ["action": "status", "status": 503, "path": "/send/", "times": 2]),
        Broken(name: "connection dropped", rule: ["action": "drop", "path": "/send/", "times": 1]),
        Broken(name: "slow network", rule: ["action": "delay", "ms": 4000, "path": "/send/", "times": 1]),
    ])
    func sendOnce(_ broken: Broken) async throws {
        let stage = try await Stage()
        try await stage.proxy.fault(broken.rule)
        let start = ContinuousClock.now
        for number in 1...3 { try await stage.timeline.send(text: "m\(number)", mentions: []) }
        try await stage.wait(90, "all three sent (\(broken.name))") {
            (1...3).allSatisfy { stage.mirror.own("m\($0)")?.sendState == .sent }
        }
        stage.report("sendOnce, \(broken.name)", since: start)
        #expect(try await stage.proxy.hits() >= 1, "the fault was met")
        try await stage.proxy.heal()
        let bodies = try await ServerMessages(server: stage.direct, room: stage.room).bodies(user: stage.user, password: stage.password)
        #expect(Array(bodies.reversed()) == ["m1", "m2", "m3"], "\(broken.name)")
    }

    struct Broken: Sendable, CustomTestStringConvertible {
        let name: String
        let rule: [String: any Sendable]
        var testDescription: String { name }
    }
}

/// A signed-in, syncing account with one open room, its peer, and the proxy between them.
private struct Stage {
    let proxy = ProxyControl()
    let user = env["HALO_FAULT_USER"] ?? "", password = env["HALO_FAULT_PASSWORD"] ?? ""
    let direct = env["HALO_FAULT_DIRECT"] ?? ""
    let peer: Peer
    let room: RoomID
    let sync: SyncFollower
    let timeline: any TimelineSession
    let mirror: TimelineMirror

    init() async throws {
        try await proxy.heal()
        let session = MatrixSessionPort(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("halo-fault-\(UUID().uuidString)"))
        let details = try await session.loginDetails(server: env["HALO_FAULT_SERVER"] ?? "")
        _ = try await session.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "fault"), on: details)
        let proxy = proxy
        Cleanup.current.add {
            try? await proxy.heal()
            try? await session.logout()
        }
        peer = try await Peer(server: direct, user: user + "peer", password: password)
        let peer = peer
        Cleanup.current.add { await peer.logout() }
        room = try await peer.makeRoom()
        let joined = try await Peer(server: direct, user: user, password: password)
        try await joined.join(room)
        await joined.logout()
        sync = SyncFollower(MatrixSyncPort(session: session))
        let sync = sync
        Cleanup.current.add { await sync.stop() }
        try await sync.start()
        var opened: (any TimelineSession)?
        for _ in 0..<60 where opened == nil {
            opened = try? await MatrixTimelinePort(session: session).open(room: room)
            if opened == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        timeline = try #require(opened)
        mirror = TimelineMirror(timeline.items())
    }

    func wait(_ seconds: Double, _ what: String, _ done: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try await !done() {
            guard ContinuousClock.now < deadline else { throw ContractViolation("\(what): not within \(seconds) s (sync \(String(describing: sync.last)))") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func report(_ name: String, since start: ContinuousClock.Instant) {
        let time = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
        print("FAULT \(name): \(time)")
    }
}

/// Restarts the loop when it ends with `.failed`, as `SyncCoordinator` does in the app.
private final class SyncFollower: @unchecked Sendable {  // fields are guarded by `lock`
    private let port: MatrixSyncPort
    private let lock = NSLock()
    private var status: SyncStatus?
    private var task: Task<Void, Never>?

    init(_ port: MatrixSyncPort) { self.port = port }

    var last: SyncStatus? { lock.withLock { status } }

    func start() async throws {
        let statuses = port.statuses()
        let follower = Task { [weak self, port] in
            for await status in statuses {
                self?.lock.withLock { self?.status = status }
                if status == .failed {
                    try? await Task.sleep(for: .seconds(1))
                    try? await port.start()
                }
            }
        }
        lock.withLock { task = follower }
        try await port.start()
    }

    func stop() async {
        lock.withLock { task }?.cancel()
        await port.stop()
    }
}

private struct ProxyControl: Sendable {
    func fault(_ rule: [String: any Sendable]) async throws { _ = try await call("POST", "/rules", rule) }
    func heal() async throws { _ = try await call("DELETE", "/rules", nil) }
    func hits() async throws -> Int { (try await call("GET", "/rules", nil) as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["hits"] as? Int ?? 0) } }

    private func call(_ method: String, _ path: String, _ body: [String: any Sendable]?) async throws -> Any {
        guard let url = URL(string: (env["HALO_FAULT_CONTROL"] ?? "") + path) else { throw ContractViolation("no proxy") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContractViolation("the proxy refused \(method) \(path)") }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
}

/// Another account over plain HTTP, past the proxy.
private struct Peer: Sendable {
    let base: String
    let token: String

    init(server: String, user: String, password: String) async throws {
        base = server + "/_matrix/client/v3"
        let login = try await Self.call("POST", base + "/login", nil, [
            "type": "m.login.password", "identifier": ["type": "m.id.user", "user": user], "password": password])
        token = login["access_token"] as? String ?? ""
    }

    func makeRoom() async throws -> RoomID {
        try RoomID(try await Self.call("POST", base + "/createRoom", token, ["preset": "public_chat"])["room_id"] as? String ?? "")
    }

    func join(_ room: RoomID) async throws { _ = try await Self.call("POST", base + "/rooms/\(room.rawValue)/join", token, [:]) }

    func send(_ text: String, to room: RoomID) async throws {
        _ = try await Self.call("PUT", base + "/rooms/\(room.rawValue)/send/m.room.message/\(UUID().uuidString)", token, ["msgtype": "m.text", "body": text])
    }

    func logout() async { _ = try? await Self.call("POST", base + "/logout", token, [:]) }

    private static func call(_ method: String, _ url: String, _ token: String?, _ body: [String: Any]) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContractViolation("\(method) failed: \(String(decoding: data.prefix(120), as: UTF8.self))") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
