import Darwin
import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// What reading messages for Halo's own search index costs (ROADMAP M17-8, V-SEARCH-2). Measurements, not tests of behaviour, except that they
/// check the reads are complete. Prints `SPIKE {json}`; run through `scripts/scale-measure.py --search`.
@Suite("Search spike", .serialized, .cleansUp, .enabled(if: env["HALO_SCALE_SPIKE"] != nil, "needs scripts/scale-measure.py --search"))
struct SearchSpikeMeasurements {
    private let clock = ContinuousClock()

    @Test("Live lane: every room after the first sync, 200 rooms after a catch-up, rooms with a gap", .timeLimit(.minutes(30)), .enabled(if: env["HALO_SCALE_USER"] == "scale1000" && !["memory", "listen", "bulk"].contains(env["HALO_SCALE_HISTORY"])))
    func live() async throws {
        var result: [String: Any] = [:]
        let memory = PeakMemory()
        defer { memory.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, stored) = try await signIn(directory)
        let first = follow(session)
        try await session.startSync()
        try await first.waitForSync(1, seconds: 900)
        try await Task.sleep(for: .seconds(20))
        let reader = try await SearchSpikeReader(session: session)
        let rooms = first.rooms.filter { $0.membership == .joined }.map(\.id)
        let probe = try await Probe(server: env["HALO_SCALE_DIRECT"] ?? "", user: "scaleprobe", password: env["HALO_SCALE_PROBE_PASSWORD"] ?? "")
        Cleanup.current.add { await probe.logout() }
        let shared = try await probe.rooms()

        // 1. Every room once, as after a first sync, while a message arrives.
        var known: [RoomID: Set<EventID>] = [:]
        var times: [Double] = []
        result["memoryBeforeMB"] = memory.currentMB
        memory.reset()
        await ScaleStage.proxy("DELETE", "/stats")
        var cpu = ScaleStage.cpuSeconds()
        var start = clock.now
        let syncs = first.syncs
        async let liveMessage: Double = {
            try await Task.sleep(for: .seconds(2))
            let sent = clock.now
            if let room = shared.last { try await probe.send("while indexing", to: room, transaction: UUID().uuidString) }
            try await first.waitForSync(syncs + 1, seconds: 60)
            return (clock.now - sent).seconds
        }()
        var messages = 0
        for room in rooms {
            let began = clock.now
            let slice = try await reader.recent(room)
            times.append((clock.now - began).seconds)
            known[room] = Set(slice.events.compactMap(\.eventID))
            messages += slice.messages.count
        }
        result["allRooms"] = measured(since: start, cpu: cpu, times: times, memory: memory).merging(
            ["rooms": rooms.count, "messages": messages, "requests": await ScaleStage.traffic().requests, "liveMessageSeconds": try await liveMessage]) { $1 }

        // 2. The same again: nothing new.
        cpu = ScaleStage.cpuSeconds()
        start = clock.now
        times = []
        for room in rooms.prefix(200) {
            let began = clock.now
            _ = try await reader.recent(room)
            times.append((clock.now - began).seconds)
        }
        result["again200"] = measured(since: start, cpu: cpu, times: times, memory: memory)
        try await Task.sleep(for: .seconds(10))
        cpu = ScaleStage.cpuSeconds()
        try await Task.sleep(for: .seconds(60))
        result["idleCPUSecondsPerMinute"] = ScaleStage.cpuSeconds() - cpu
        result["threads"] = ScaleStage.threads()
        result["settledMB"] = memory.currentMB

        // 3. Away for a day: 200 rooms with five messages, five rooms with 60 (a limited sync leaves a gap), restart on stored data.
        await session.stopSync()
        first.cancel()
        var expected: [String: Set<String>] = [:]
        for (index, room) in shared.prefix(205).enumerated() {
            for number in 0..<(index < 200 ? 5 : 60) {
                expected[room, default: []].insert(try await probe.send("away \(number)", to: room, transaction: UUID().uuidString))
            }
        }
        let again = ScaleStage.port(directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        let second = follow(again)
        try await second.waitForRooms(rooms.count, seconds: 120)
        let catchUp = clock.now
        try await again.startSync()
        try await second.waitForSync(1, seconds: 300)
        result["catchUpSeconds"] = (clock.now - catchUp).seconds
        memory.reset()
        await ScaleStage.proxy("DELETE", "/stats")
        cpu = ScaleStage.cpuSeconds()
        start = clock.now
        times = []
        var missing = 0, pages = 0
        let secondReader = try await SearchSpikeReader(session: again)
        for (raw, ids) in expected {
            let room = try RoomID(raw)
            let began = clock.now
            let slice = try await secondReader.recent(room, known: known[room] ?? [], maxPages: 6)
            times.append((clock.now - began).seconds)
            pages += slice.pages
            missing += ids.subtracting(slice.events.compactMap { $0.eventID?.rawValue }).count
        }
        result["catchUp"] = measured(since: start, cpu: cpu, times: times, memory: memory).merging(
            ["rooms": expected.count, "pages": pages, "missing": missing, "requests": await ScaleStage.traffic().requests]) { $1 }
        #expect(missing == 0)

        // 4. History lane on ordinary rooms: from the oldest known event to the start.
        memory.reset()
        await ScaleStage.proxy("DELETE", "/stats")
        cpu = ScaleStage.cpuSeconds()
        start = clock.now
        times = []
        var complete = 0, read = 0
        for room in rooms.prefix(100) {
            let began = clock.now
            guard let oldest = try await secondReader.recent(room).oldest else { continue }
            let slice = try await secondReader.history(room, before: oldest, pages: 10)
            times.append((clock.now - began).seconds)
            if slice.reachedStart { complete += 1 }
            read += slice.messages.count
        }
        let traffic = await ScaleStage.traffic()
        result["history100"] = measured(since: start, cpu: cpu, times: times, memory: memory).merging(
            ["complete": complete, "messages": read, "requests": traffic.requests, "MB": traffic.megabytes]) { $1 }
        await again.stopSync()
        second.cancel()
        try report(result)
    }

    @Test("Live lane on listeners: catch-up of 205 rooms, gaps read by a client of its own", .timeLimit(.minutes(20)), .enabled(if: env["HALO_SCALE_USER"] == "scale1000" && env["HALO_SCALE_HISTORY"] == "listen"))
    func listeners() async throws {
        var result: [String: Any] = [:]
        let memory = PeakMemory()
        defer { memory.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, stored) = try await signIn(directory)
        let first = follow(session)
        try await session.startSync()
        try await first.waitForSync(1, seconds: 900)
        try await settle(memory)
        let rooms = first.rooms.filter { $0.membership == .joined }.map(\.id)
        let probe = try await Probe(server: env["HALO_SCALE_DIRECT"] ?? "", user: "scaleprobe", password: env["HALO_SCALE_PROBE_PASSWORD"] ?? "")
        Cleanup.current.add { await probe.logout() }
        let shared = try await probe.rooms()

        // 1. Subscribing to every room, and what it adds.
        result["settledMB"] = memory.currentMB
        let seen = SearchSpikeSeen()
        var cpu = ScaleStage.cpuSeconds(), start = clock.now
        var handles: [TaskHandle] = []
        for room in rooms { handles += SearchSpikeListener.subscribe(try await session.room(room), seen: seen) }
        result["subscribe"] = ["seconds": (clock.now - start).seconds, "cpuSeconds": ScaleStage.cpuSeconds() - cpu, "handles": handles.count]
        try await Task.sleep(for: .seconds(5))
        result["subscribedMB"] = memory.currentMB
        cpu = ScaleStage.cpuSeconds()
        try await Task.sleep(for: .seconds(60))
        result["idleCPUSecondsPerMinute"] = ScaleStage.cpuSeconds() - cpu
        result["threads"] = ScaleStage.threads()
        // 2. Live: ten messages in ten rooms.
        var sent: [String: Set<String>] = [:]
        for room in shared.prefix(10) { for number in 0..<10 { sent[room, default: []].insert(try await probe.send("live \(number)", to: room, transaction: UUID().uuidString)) } }
        try await Task.sleep(for: .seconds(15))
        result["liveMissing"] = sent.reduce(0) { sum, entry in sum + entry.value.subtracting(seen.value.withLock { $0.messages[entry.key] ?? [] }).count }
        for handle in handles { handle.cancel() }
        handles = []

        // 3. Away for a day, restart: listeners first, then the sync.
        await session.stopSync()
        first.cancel()
        var expected: [String: Set<String>] = [:]
        for (index, room) in shared.prefix(205).enumerated() {
            for number in 0..<(index < 200 ? 5 : 60) { expected[room, default: []].insert(try await probe.send("away \(number)", to: room, transaction: UUID().uuidString)) }
        }
        let again = ScaleStage.port(directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        let second = follow(again)
        try await second.waitForRooms(rooms.count, seconds: 120)
        let caught = SearchSpikeSeen()
        for room in rooms { handles += SearchSpikeListener.subscribe(try await again.room(room), seen: caught) }
        start = clock.now
        try await again.startSync()
        try await second.waitForSync(1, seconds: 300)
        result["catchUpSeconds"] = (clock.now - start).seconds
        try await Task.sleep(for: .seconds(3))
        var got = caught.value.withLock { $0.messages.mapValues { Set($0) } }
        result["fromListeners"] = ["rooms": got.count, "messages": got.values.reduce(0) { $0 + $1.count }]
        // A response holds at most ten events of a room: ten or more may hide a gap. Those rooms are read back by a client of its own.
        let suspects = got.filter { $0.value.count >= 10 }.map(\.key)
        await ScaleStage.proxy("DELETE", "/stats")
        start = clock.now
        var readBack = 0
        for raw in suspects {
            let room = try RoomID(raw)
            guard let earliest = caught.value.withLock({ $0.messages[raw]?.first }).flatMap({ try? EventID($0) }) else { continue }
            let reader = try SearchSpikeReader(client: try await SearchSpikeHistoryClient.make(stored, directory: directory, caches: directory.appendingPathComponent("search-caches"), room: room))
            let slice = try await reader.history(room, before: earliest, pages: 1)
            got[raw, default: []].formUnion(slice.events.compactMap { $0.eventID?.rawValue })
            readBack += 1
        }
        result["gaps"] = ["suspects": suspects.count, "seconds": (clock.now - start).seconds, "requests": await ScaleStage.traffic().requests]
        let missing = expected.reduce(0) { $0 + $1.value.subtracting(got[$1.key] ?? []).count }
        result["missing"] = missing
        await again.stopSync()
        second.cancel()
        for handle in handles { handle.cancel() }
        try report(result)
        #expect(missing == 0)
    }

    @Test("First indexing: the newest pages of 1,000 rooms through clients of their own", .timeLimit(.minutes(30)), .enabled(if: env["HALO_SCALE_USER"] == "scale1000" && env["HALO_SCALE_HISTORY"] == "bulk"))
    func bulk() async throws {
        let memory = PeakMemory()
        defer { memory.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, stored) = try await signIn(directory)
        let list = follow(session)
        try await session.startSync()
        try await list.waitForSync(1, seconds: 900)
        try await settle(memory)
        let rooms = list.rooms.filter { $0.membership == .joined }.map(\.id)
        let before = memory.currentMB
        memory.reset()
        await ScaleStage.proxy("DELETE", "/stats")
        let cpu = ScaleStage.cpuSeconds(), start = clock.now
        var times: [Double] = [], messages = 0, complete = 0, curve: [Double] = []
        var shared: Client?
        for (index, room) in rooms.prefix(Int(env["HALO_SCALE_ROUNDS"] ?? "") ?? 1000).enumerated() {
            let began = clock.now
            // The cache of its own starts empty: the newest page comes from the server.
            if index % 20 == 0 {
                shared = nil
                shared = try await SearchSpikeHistoryClient.make(stored, directory: directory, caches: directory.appendingPathComponent("search-caches-\(index)"), room: nil)
            }
            let client = try #require(shared)
            let reader = try SearchSpikeReader(client: client)
            let made = (clock.now - began).seconds
            // Not a live timeline: paging one feeds the SDK's in-memory index, 0.4 s CPU and a pool of threads per room (measured).
            guard let newest = try await newestEvent(in: room, as: client) else { continue }
            let slice = try await reader.history(room, before: newest, pages: 10)
            if index % 10 == 0 { print("PROGRESS \(index): client \(made) s, read \((clock.now - began).seconds - made) s, \(slice.pages) pages, \(slice.events.count) events") }
            times.append((clock.now - began).seconds)
            messages += slice.messages.count
            if slice.reachedStart { complete += 1 }
            if times.count % 100 == 0 { curve.append(memory.currentMB.rounded()) }
        }
        let traffic = await ScaleStage.traffic()
        var result = measured(since: start, cpu: cpu, times: times, memory: memory)
        try await Task.sleep(for: .seconds(5))
        result.merge(["rooms": rooms.count, "messages": messages, "complete": complete, "requests": traffic.requests, "MB": traffic.megabytes, "memoryBeforeMB": before,
                      "endpoints": await ScaleStage.endpoints(), "memoryCurveMB": curve, "memoryAfterMB": memory.currentMB, "threads": ScaleStage.threads()]) { $1 }
        await session.stopSync()
        list.cancel()
        try report(["bulk": result])
    }

    @Test("Memory: reading every room four times, and how much of the growth the allocator only holds on to", .timeLimit(.minutes(15)), .enabled(if: env["HALO_SCALE_USER"] == "scale1000" && env["HALO_SCALE_HISTORY"] == "memory"))
    func memoryOfReads() async throws {
        let memory = PeakMemory()
        defer { memory.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, _) = try await signIn(directory)
        let list = follow(session)
        try await session.startSync()
        try await list.waitForSync(1, seconds: 900)
        try await Task.sleep(for: .seconds(20))
        let reader = try await SearchSpikeReader(session: session)
        let rooms = list.rooms.filter { $0.membership == .joined }.map(\.id)
        func relieved() async throws -> Double {
            try await Task.sleep(for: .seconds(5))
            malloc_zone_pressure_relief(nil, 0)
            try await Task.sleep(for: .seconds(1))
            return memory.currentMB.rounded()
        }
        var steps = ["0 at once": memory.currentMB.rounded()]
        try await settle(memory)
        steps["0 settled"] = try await relieved()
        let name = try RoomID(rooms[0].rawValue)
        for _ in 0..<500 { _ = try await reader.recent(name) }
        steps["1 one room 500 times"] = try await relieved()
        for pass in 1...2 {
            for room in rooms { _ = try await reader.room(room).timelineWithConfiguration(configuration: SearchSpikeReader.plain) }
            steps["2 timelines without listener, pass \(pass)"] = try await relieved()
        }
        for pass in 1...3 {
            for room in rooms { _ = try await reader.recent(room) }
            steps["3 read, pass \(pass)"] = try await relieved()
        }
        steps["mirrors alive"] = Double(SpikeMirror.alive.withLock { $0 })
        steps["threads"] = Double(ScaleStage.threads())
        await session.stopSync()
        list.cancel()
        try report(["memory": steps])
    }

    @Test("History lane: the 20,000-event room in slices, each resuming from the oldest event of the one before", .timeLimit(.minutes(60)), .enabled(if: env["HALO_SCALE_USER"] == "scalebig"))
    func deepRoom() async throws {
        let memory = PeakMemory()
        defer { memory.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, stored) = try await signIn(directory)
        let list = follow(session)
        try await session.startSync()
        try await list.waitForSync(1, seconds: 300)
        try await Task.sleep(for: .seconds(5))
        let reader = try await SearchSpikeReader(session: session)
        var target: (room: RoomID, slice: SearchSpikeReader.Slice)?
        for room in list.rooms {
            let slice = try await reader.recent(room.id)
            if slice.messages.contains(where: { if case .media = $0.kind { true } else { false } }) { target = (room.id, slice) }
        }
        let (room, newest) = try #require(target)
        var seen = Set(newest.messages.compactMap(\.eventID))
        var oldest = try #require(newest.oldest)
        let before = memory.currentMB, storeBefore = size(of: directory)
        memory.reset()
        await ScaleStage.proxy("DELETE", "/stats")
        let cpu = ScaleStage.cpuSeconds(), start = clock.now
        var times: [Double] = [], settled: [Double] = [], repeated = 0, slices = 0, stuck = false, clientTimes: [Double] = []
        // HALO_SCALE_HISTORY=own: a client of its own per ten slices. Otherwise the app's client.
        let caches = directory.appendingPathComponent("search-caches")
        var own: SearchSpikeReader?
        let newestAnchor = oldest
        var rounds = 0
        while slices < 400 {
            if env["HALO_SCALE_HISTORY"] == "own", slices % 10 == 0 {
                own = nil
                let made = clock.now
                own = try SearchSpikeReader(client: try await SearchSpikeHistoryClient.make(stored, directory: directory, caches: caches, room: room))
                clientTimes.append((clock.now - made).seconds)
            }
            let began = clock.now
            let slice = try await (own ?? reader).history(room, before: oldest, pages: 5)
            times.append((clock.now - began).seconds)
            slices += 1
            let ids = slice.messages.compactMap(\.eventID)
            repeated += ids.filter { seen.contains($0) }.count
            seen.formUnion(ids)
            settled.append(memory.currentMB)
            if slice.reachedStart {
                rounds += 1
                if rounds >= Int(env["HALO_SCALE_ROUNDS"] ?? "1") ?? 1 { break }
                oldest = newestAnchor  // the same room again: only memory is of interest now
                continue
            }
            guard let next = slice.oldest, next != oldest else { stuck = true; break }
            oldest = next
        }
        let traffic = await ScaleStage.traffic()
        own = nil
        try await Task.sleep(for: .seconds(2))
        var result = measured(since: start, cpu: cpu, times: times, memory: memory)
        result.merge([
            "clientSeconds": clientTimes, "searchCachesMB": size(of: caches),
            "slices": slices, "messages": seen.count, "repeated": repeated, "stuck": stuck, "requests": traffic.requests, "MB": traffic.megabytes,
            "memoryBeforeMB": before, "memoryAfterSlicesMB": settled.enumerated().filter { $0.offset % 8 == 0 }.map { $0.element.rounded() },
            "memoryEndMB": memory.currentMB, "storeGrowthMB": size(of: directory) - storeBefore, "threads": ScaleStage.threads(),
        ]) { $1 }
        await session.stopSync()
        list.cancel()
        try report(["deepRoom": result])
        #expect(!stuck)
        #expect(seen.count >= 20_000)
    }

    // MARK: Helpers

    /// The room's newest event, from the server: the SDK's latest event carries no ID (F-FFI-15).
    private func newestEvent(in room: RoomID, as client: Client) async throws -> EventID? {
        let sdk = try client.session()
        let base = sdk.homeserverUrl.hasSuffix("/") ? sdk.homeserverUrl : sdk.homeserverUrl + "/"
        guard let url = URL(string: base + "_matrix/client/v3/rooms/\(room.rawValue)/messages?dir=b&limit=1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + sdk.accessToken, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let chunk = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["chunk"] as? [[String: Any]]
        return (chunk?.first?["event_id"] as? String).flatMap { try? EventID($0) }
    }

    /// The room list still rebuilds and memory still grows after the first sync: the baseline is what it settles at.
    private func settle(_ memory: PeakMemory) async throws {
        var last = 0.0, waited = 0
        while abs(memory.currentMB - last) > 0.5, waited < 180 {
            last = memory.currentMB
            try await Task.sleep(for: .seconds(20))
            waited += 20
        }
    }

    private func signIn(_ directory: URL) async throws -> (MatrixSessionPort, StoredSession) {
        let session = ScaleStage.port(directory)
        let details = try await session.loginDetails(server: env["HALO_SCALE_SERVER"] ?? "")
        let stored = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_SCALE_USER"] ?? "", password: env["HALO_SCALE_PASSWORD"] ?? "", deviceDisplayName: "scale"), on: details)
        Cleanup.current.add { try? await session.logout() }
        return (session, stored)
    }

    private func follow(_ session: MatrixSessionPort) -> ListFollower {
        let follower = ListFollower()
        follower.run(MatrixRoomListPort(session: session).updates(filter: .all))
        return follower
    }

    private func measured(since start: ContinuousClock.Instant, cpu: Double, times: [Double], memory: PeakMemory) -> [String: Any] {
        let sorted = times.sorted()
        func percentile(_ share: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
        return ["seconds": (clock.now - start).seconds, "cpuSeconds": ScaleStage.cpuSeconds() - cpu, "p50": percentile(0.5), "p95": percentile(0.95),
                "max": sorted.last ?? 0, "peakMB": memory.peakMB]
    }

    private func size(of directory: URL) -> Double {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])?.allObjects as? [URL] ?? []
        return Double(files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }) / 1_048_576
    }

    private func report(_ result: [String: Any]) throws {
        print("SPIKE \(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))")
    }
}
