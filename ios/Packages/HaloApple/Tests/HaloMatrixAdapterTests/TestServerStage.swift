import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// What the suites against infra/test's throwaway server share (`infra/test/run.sh faults|interop`).
private let env = ProcessInfo.processInfo.environment

enum TestServer {
    static let configured = env["HALO_FAULT_CONTROL"] != nil
}

/// A signed-in, syncing account with one open room, its peer, and the proxy between them.
struct TestStage {
    let proxy = ProxyControl()
    let user = env["HALO_FAULT_USER"] ?? "", password = env["HALO_FAULT_PASSWORD"] ?? ""
    let direct = env["HALO_FAULT_DIRECT"] ?? ""
    let peer: TestPeer
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
        peer = try await TestPeer(server: direct, user: user + "peer", password: password)
        let peer = peer
        Cleanup.current.add { await peer.logout() }
        room = try await peer.makeRoom()
        let joined = try await TestPeer(server: direct, user: user, password: password)
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
final class SyncFollower: @unchecked Sendable {  // fields are guarded by `lock`
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

struct ProxyControl: Sendable {
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
struct TestPeer: Sendable {
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

    @discardableResult
    func send(_ text: String, to room: RoomID) async throws -> String {
        try await send(["msgtype": "m.text", "body": text], to: room)
    }

    @discardableResult
    func send(_ content: [String: Any], type: String = "m.room.message", to room: RoomID) async throws -> String {
        try await Self.call("PUT", base + "/rooms/\(room.rawValue)/send/\(type)/\(UUID().uuidString)", token, content)["event_id"] as? String ?? ""
    }

    func redact(_ event: String, in room: RoomID) async throws {
        _ = try await Self.call("PUT", base + "/rooms/\(room.rawValue)/redact/\(event)/\(UUID().uuidString)", token, [:])
    }

    /// The room's newest events as the server has them, oldest first.
    func events(in room: RoomID) async throws -> [[String: Any]] {
        let page = try await Self.call("GET", base + "/rooms/\(room.rawValue)/messages?dir=b&limit=100", token, nil)
        return (page["chunk"] as? [[String: Any]] ?? []).reversed()
    }

    func upload(_ data: Data, type: String) async throws -> String {
        guard let target = URL(string: base.replacingOccurrences(of: "/client/v3", with: "/media/v3/upload")) else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (answer, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: answer) as? [String: Any])?["content_uri"] as? String ?? ""
    }

    func logout() async { _ = try? await Self.call("POST", base + "/logout", token, [:]) }

    private static func call(_ method: String, _ url: String, _ token: String?, _ body: [String: Any]?) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContractViolation("\(method) failed: \(String(decoding: data.prefix(120), as: UTF8.self))") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
