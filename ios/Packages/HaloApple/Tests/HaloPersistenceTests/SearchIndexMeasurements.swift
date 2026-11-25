import Darwin
import Foundation
import GRDB
import Testing

/// What an FTS5 index of 300,000 messages costs through GRDB (ROADMAP M17-8, V-SEARCH-2). A measurement with the schema of DATA_MODELS §3b;
/// prints one `SPIKE` line. Runs only with HALO_SEARCH_SPIKE=1 (TEST_RUNNER_HALO_SEARCH_SPIKE in a simulator).
@Suite("Search index measurements", .enabled(if: ProcessInfo.processInfo.environment["HALO_SEARCH_SPIKE"] != nil, "set HALO_SEARCH_SPIKE"))
struct SearchIndexMeasurements {
    @Test("300,000 messages: writing in batches, size, queries", .timeLimit(.minutes(20)))
    func threeHundredThousand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-fts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = NORMAL") }
        let pool = try DatabasePool(path: directory.appendingPathComponent("search-index.sqlite").path, configuration: configuration)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE event (
                  id INTEGER PRIMARY KEY, room INTEGER NOT NULL, sender INTEGER NOT NULL, event_id TEXT NOT NULL, media_index INTEGER NOT NULL DEFAULT 0,
                  thread_root TEXT, ts INTEGER NOT NULL, kind INTEGER NOT NULL, body TEXT NOT NULL, searchable TEXT NOT NULL,
                  UNIQUE (room, event_id, media_index));
                CREATE INDEX event_room ON event(room, ts DESC);
                CREATE INDEX event_kind ON event(kind, ts DESC);
                CREATE INDEX event_time ON event(ts DESC);
                """)
            try db.create(virtualTable: "event_fts", using: FTS5()) { table in
                table.synchronize(withTable: "event")
                table.tokenizer = .unicode61(diacritics: .remove)
                table.prefixes = [2, 3]
                table.column("searchable")
            }
        }
        var generator = Generator()
        let total = 300_000, batch = 100
        var result: [String: Any] = ["messages": total]
        var cpu = cpuSeconds(), start = ContinuousClock.now, slowest = 0.0
        var number = 0
        while number < total {
            let rows = (0..<batch).map { generator.row(number + $0) }
            let began = ContinuousClock.now
            try await pool.write { db in
                let statement = try db.cachedStatement(sql: """
                    INSERT INTO event (room, sender, event_id, ts, kind, body, searchable) VALUES (?, ?, ?, ?, 0, ?, ?)
                    ON CONFLICT (room, event_id, media_index) DO UPDATE SET body = excluded.body, searchable = excluded.searchable
                    """)
                for row in rows { try statement.execute(arguments: [row.room, row.sender, row.event, row.ts, row.body, row.searchable]) }
            }
            slowest = max(slowest, seconds(since: began))
            number += batch
        }
        result["writeSeconds"] = seconds(since: start)
        result["writeCPU"] = cpuSeconds() - cpu
        result["slowestBatchMs"] = slowest * 1000
        try await pool.barrierWriteWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        result["MB"] = Double((try FileManager.default.attributesOfItem(atPath: pool.path)[.size] as? Int) ?? 0) / 1e6

        // First page of 30, newest first.
        let queries: [(String, String)] = [
            ("rare word", "\"\(generator.words[19_000])\"*"), ("common word", "\"\(generator.words[0])\"*"), ("one letter", "\"a\"*"), ("two letters", "\"ab\"*"),
            ("two CJK characters", "\"\(generator.han[0]) \(generator.han[1])\"*"), ("one CJK character", "\"\(generator.han[0])\"*"),
            ("two words", "\"\(generator.words[0])\" \"\(generator.words[1])\"*"),
        ]
        let sql = "SELECT e.id FROM event_fts f JOIN event e ON e.id = f.rowid WHERE f.searchable MATCH ? ORDER BY e.ts DESC, e.id DESC LIMIT 30"
        for (name, match) in queries {
            var times: [Double] = []
            for _ in 0..<20 {
                start = .now
                _ = try await pool.read { db in try Int64.fetchAll(db, sql: sql, arguments: [match]) }
                times.append(seconds(since: start) * 1000)
            }
            let hits = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM event_fts WHERE searchable MATCH ?", arguments: [match]) ?? 0 }
            result["query " + name] = ["hits": hits, "p50ms": times.sorted()[10], "p95ms": times.sorted()[18]]
        }
        // The same within one room (M20-11).
        start = .now
        _ = try await pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT e.id FROM event_fts f JOIN event e ON e.id = f.rowid WHERE f.searchable MATCH ? AND e.room = 7 ORDER BY e.ts DESC LIMIT 30", arguments: [queries[1].1])
        }
        result["query in a room ms"] = seconds(since: start) * 1000
        // An edit and a deletion.
        cpu = cpuSeconds()
        start = .now
        try await pool.write { db in
            try db.execute(sql: "UPDATE event SET searchable = 'edited' WHERE id = 1000")
            try db.execute(sql: "DELETE FROM event WHERE id = 1001")
        }
        result["editAndDeleteMs"] = seconds(since: start) * 1000
        start = .now
        try await pool.write { db in try db.execute(sql: "DELETE FROM event WHERE room = 3") }
        result["leaveRoomMs"] = seconds(since: start) * 1000
        print("SPIKE \(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))")
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func value(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return value(usage.ru_utime) + value(usage.ru_stime)
    }

    /// Messages of 2 to 25 words or 3 to 40 CJK characters, common words more often; the same every run.
    private struct Generator {
        var state: UInt64 = 1
        var words: [String] = []
        let han = (0..<3000).map { String(UnicodeScalar(0x4E00 + $0) ?? "?") }

        init() {
            for _ in 0..<20_000 {
                let length = 2 + next(8)
                words.append(String((0..<length).map { _ in Character(UnicodeScalar(UInt8(97 + next(26)))) }))
            }
        }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        mutating func row(_ number: Int) -> (room: Int, sender: Int, event: String, ts: Int, body: String, searchable: String) {
            let body: String, searchable: String
            if next(2) == 0 {
                body = (0..<(2 + next(24))).map { _ in words[next(200) * next(101)] }.joined(separator: " ")
                searchable = body
            } else {
                let characters = (0..<(3 + next(38))).map { _ in han[next(60) * next(51)] }
                body = characters.joined()
                searchable = characters.joined(separator: " ")
            }
            return (next(1000), next(500), "$" + UUID().uuidString + UUID().uuidString.prefix(7), 1_700_000_000_000 + number * 1000, body, searchable)
        }
    }
}
