import Darwin
import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// Classic sync on a large account (ROADMAP M17-4, V-SCALE-1). Not a test of behaviour: it prints one `SCALE {json}` line that
/// `scripts/scale-measure.py` turns into the table of TEST_STRATEGY §7. Runs only against the M17-3 fixture server, through that script.
private let env = ProcessInfo.processInfo.environment

@Suite("Scale measurements", .serialized, .cleansUp, .enabled(if: env["HALO_SCALE_SERVER"] != nil, "needs scripts/scale-measure.py"))
struct ScaleMeasurements {
    private let clock = ContinuousClock()

    @Test("First sync, restart, idle, live message and catch-up", .timeLimit(.minutes(30)))
    func account() async throws {
        let server = env["HALO_SCALE_SERVER"] ?? "", user = env["HALO_SCALE_USER"] ?? ""
        let expected = Int(env["HALO_SCALE_ROOMS"] ?? "") ?? 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var result: [String: Any] = ["account": user, "rooms": expected]
        let memory = PeakMemory()

        // 1. Sign-in and first sync, as the app does it: the list subscribes, then the loop starts.
        let session = MatrixSessionPort(baseDirectory: directory)
        let details = try await session.loginDetails(server: server)
        let stored = try await session.loginPassword(
            PasswordCredentials(username: user, password: env["HALO_SCALE_PASSWORD"] ?? "", deviceDisplayName: "scale"), on: details)
        Cleanup.current.add { try? await session.logout() }
        result["memoryBeforeMB"] = memory.currentMB
        await proxy("DELETE", "/stats")
        memory.reset()
        let firstStart = clock.now
        let first = follow(session)
        try await session.startSync()
        result["firstListSeconds"] = try await seconds(since: firstStart) { try await first.waitForRooms(expected, seconds: 900) }
        result["firstSyncSeconds"] = try await seconds(since: firstStart) { try await first.waitForSync(1, seconds: 900) }
        result["firstPeakMB"] = memory.peakMB
        result["firstTraffic"] = await proxy("GET", "/stats")

        // 2. Idle in the foreground: the long poll and whatever the SDK does on its own.
        try await Task.sleep(for: .seconds(20))  // let the key queries of the first sync finish
        result["settledTraffic"] = await proxy("GET", "/stats")
        await proxy("DELETE", "/stats")
        let cpuBefore = cpuSeconds()
        try await Task.sleep(for: .seconds(60))
        result["idleCPUSecondsPerMinute"] = cpuSeconds() - cpuBefore
        result["idleTraffic"] = await proxy("GET", "/stats")
        result["settledMB"] = memory.currentMB
        result["storeMB"] = size(of: directory)

        // 3. One message while the app is open.
        let probe = try await Probe(server: env["HALO_SCALE_DIRECT"] ?? "", user: "scaleprobe", password: env["HALO_SCALE_PROBE_PASSWORD"] ?? "")
        Cleanup.current.add { await probe.logout() }
        let shared = try await probe.rooms().filter { room in first.rooms.contains { $0.id.rawValue == room } }
        if let room = shared.first {
            let syncs = first.syncs
            let sent = clock.now
            try await probe.send("live", to: room, transaction: UUID().uuidString)
            result["liveMessageSeconds"] = try await seconds(since: sent) { try await first.waitForSync(syncs + 1, seconds: 60) }
        }

        // 4. Away for a day: 200 rooms with five messages each, then the app starts again on its stored data.
        await session.stopSync()
        first.cancel()
        for room in shared.prefix(200) {
            for number in 0..<5 { try await probe.send("away \(number)", to: room, transaction: UUID().uuidString) }
        }
        await proxy("DELETE", "/stats")
        memory.reset()
        let restart = clock.now
        let again = MatrixSessionPort(baseDirectory: directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        result["restoreSeconds"] = (clock.now - restart).seconds
        let second = follow(again)
        result["cachedListSeconds"] = try await seconds(since: restart) { try await second.waitForRooms(expected, seconds: 120) }
        let catchUp = clock.now
        try await again.startSync()
        result["catchUpSeconds"] = try await seconds(since: catchUp) { try await second.waitForSync(1, seconds: 300) }
        result["catchUpRooms"] = min(200, shared.count)
        result["catchUpPeakMB"] = memory.peakMB
        result["catchUpTraffic"] = await proxy("GET", "/stats")
        await again.stopSync()
        second.cancel()
        memory.stop()

        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("SCALE \(String(decoding: json, as: UTF8.self))")
        #expect(result["catchUpSeconds"] != nil)
    }

    // MARK: Helpers

    private func follow(_ session: MatrixSessionPort) -> ListFollower {
        let follower = ListFollower()
        follower.run(MatrixRoomListPort(session: session).updates(filter: .all))
        return follower
    }

    private func seconds(since start: ContinuousClock.Instant, _ wait: () async throws -> Void) async throws -> Double {
        try await wait()
        return (clock.now - start).seconds
    }

    @discardableResult
    private func proxy(_ method: String, _ path: String) async -> Any {
        guard let url = URL(string: (env["HALO_SCALE_CONTROL"] ?? "") + path) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let (data, _) = try? await URLSession.shared.data(for: request), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }

    private func size(of directory: URL) -> Double {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])?.allObjects as? [URL] ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        return Double(bytes) / 1_048_576
    }

    /// User and system time of this process: the part of "idle energy" a simulator can show.
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func value(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return value(usage.ru_utime) + value(usage.ru_stime)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// The room list as the app would hold it, and how many sync responses it includes.
private final class ListFollower: @unchecked Sendable {  // every field is guarded by `lock`
    private let lock = NSLock()
    private var list: [RoomSummary] = []
    private var synced = 0
    private var task: Task<Void, Never>?

    var rooms: [RoomSummary] { lock.withLock { list } }
    var syncs: Int { lock.withLock { synced } }

    func run(_ updates: AsyncStream<RoomListUpdate>) {
        task = Task { [weak self] in
            for await update in updates {
                self?.lock.withLock {
                    switch update {
                    case .diff(let diff): if var list = self?.list { try? RoomListReducer.apply(diff, to: &list); self?.list = list }
                    case .synced: self?.synced += 1
                    }
                }
            }
        }
    }

    func cancel() { task?.cancel() }
    func waitForRooms(_ count: Int, seconds: Double) async throws { try await wait(seconds) { self.rooms.count >= count } }
    func waitForSync(_ count: Int, seconds: Double) async throws { try await wait(seconds) { self.syncs >= count } }

    private func wait(_ seconds: Double, _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !done() {
            guard ContinuousClock.now < deadline else { throw ContractViolation("timed out after \(seconds) s (\(rooms.count) rooms, \(syncs) syncs)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// `phys_footprint` (what iOS limits) sampled every 20 ms on its own thread.
private final class PeakMemory: @unchecked Sendable {  // every field is guarded by `lock`
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true

    init() {
        Thread.detachNewThread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                let now = self.currentMB
                self.lock.withLock { self.peak = max(self.peak, now) }
                usleep(20_000)
            }
        }
    }

    var peakMB: Double { lock.withLock { peak } }
    func reset() { lock.withLock { peak = 0 } }
    func stop() { lock.withLock { running = false } }

    var currentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// `scaleprobe`, the other person in every room, over plain HTTP and not through the proxy.
private struct Probe {
    let base: String
    let token: String

    init(server: String, user: String, password: String) async throws {
        base = server + "/_matrix/client/v3"
        let login = try await Self.call("POST", base + "/login", nil, [
            "type": "m.login.password", "identifier": ["type": "m.id.user", "user": user], "password": password, "initial_device_display_name": "scale probe"])
        token = login["access_token"] as? String ?? ""
    }

    func rooms() async throws -> [String] { (try await Self.call("GET", base + "/joined_rooms", token, nil)["joined_rooms"] as? [String] ?? []).sorted() }

    func send(_ text: String, to room: String, transaction: String) async throws {
        _ = try await Self.call("PUT", base + "/rooms/\(room)/send/m.room.message/\(transaction)", token, ["msgtype": "m.text", "body": text])
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
