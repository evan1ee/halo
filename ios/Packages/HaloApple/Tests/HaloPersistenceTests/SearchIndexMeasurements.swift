import Darwin
import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

/// What the search index costs at 300,000 messages (MESSAGE_SEARCH §4): the shipped store and tokeniser. A measurement; prints one `SEARCH` line.
/// Runs only with HALO_SEARCH_MEASURE=1 (TEST_RUNNER_HALO_SEARCH_MEASURE in a simulator).
@Suite("Search index measurements", .enabled(if: ProcessInfo.processInfo.environment["HALO_SEARCH_MEASURE"] != nil, "set HALO_SEARCH_MEASURE"))
struct SearchIndexMeasurements {
    @Test("300,000 messages: writing in slices, size, first results", .timeLimit(.minutes(20)))
    func threeHundredThousand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-fts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchIndexStore(directory: directory, cipher: nil)
        var generator = Generator()
        let total = 300_000, slice = 500
        var result: [String: Any] = ["messages": total]
        let cpu = cpuSeconds()
        var start = ContinuousClock.now, slowest = 0.0
        for number in stride(from: 0, to: total, by: slice) {
            let entries = try (0..<slice).map { try generator.entry(number + $0) }
            let began = ContinuousClock.now
            try await store.apply([.slice(SearchHistorySlice(entries: entries, oldest: entries[0].event), .history(entries[0].room))])
            slowest = max(slowest, seconds(since: began))
        }
        result["writeSeconds"] = seconds(since: start)
        result["writeCPU"] = cpuSeconds() - cpu
        result["slowestSliceMs"] = slowest * 1000
        result["MB"] = Double(try await store.statistics().bytes) / 1e6
        let queries: [(String, String)] = [
            ("rare word", generator.words[19_000]), ("common word", generator.words[0]), ("one letter", "a"), ("two letters", "ab"),
            ("two CJK characters", generator.han[0] + generator.han[1]), ("one CJK character", generator.han[0]),
            ("two words", generator.words[0] + " " + generator.words[1]),
        ]
        for (name, query) in queries {
            let match = try #require(SearchTokeniser.matchExpression(query))
            var times: [Double] = []
            for _ in 0..<20 {
                start = .now
                _ = try await store.hits(match: match, room: nil, kinds: Set(SearchKind.allCases), excluding: [], after: nil, limit: 25)
                times.append(seconds(since: start) * 1000)
            }
            result["query " + name] = ["p50ms": times.sorted()[10], "p95ms": times.sorted()[18]]
            #expect(times.sorted()[18] < 200)
        }
        start = .now
        _ = try await store.hits(match: try #require(SearchTokeniser.matchExpression(generator.words[0])), room: try RoomID("!r7:x.org"), kinds: [.link], excluding: [], after: nil, limit: 25)
        result["query in a room, one kind, ms"] = seconds(since: start) * 1000
        start = .now
        try await store.apply([.removeRooms([try RoomID("!r3:x.org")])])
        result["leaveRoomMs"] = seconds(since: start) * 1000
        print("SEARCH \(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))")
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

    /// Messages of 2 to 25 words or 3 to 40 CJK characters, common words more often; the same every run. 600 rooms of 500 messages.
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

        mutating func entry(_ number: Int) throws -> SearchIndexEntry {
            let body = next(2) == 0
                ? (0..<(2 + next(24))).map { _ in words[next(200) * next(101)] }.joined(separator: " ")
                : (0..<(3 + next(38))).map { _ in han[next(60) * next(51)] }.joined()
            return SearchIndexEntry(
                room: try RoomID("!r\(number / 500):x.org"), event: try EventID("$\(UUID().uuidString)\(number)"), sender: try UserID("@user\(next(500)):x.org"), senderName: "User \(next(500))",
                threadRoot: nil, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)), content: SearchableContent(kind: .message, body: body))
        }
    }
}
