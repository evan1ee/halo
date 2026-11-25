import Foundation
import Testing
@testable import HaloPlatform

@Suite("MetricPayloadStore")
struct MetricPayloadStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metrickit-\(UUID().uuidString)", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(_ text: String = "x") -> Data { Data(#"{"note":"\#(text)"}"#.utf8) }

    /// A diagnostic payload as iOS writes it (shape from Apple's `MXDiagnosticPayload` JSON), with an exception message that quotes app data.
    private let crash = Data(#"""
    {"timeStampBegin":"2026-11-25 10:00:00","crashDiagnostics":[{"version":"1.0.0",
      "callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
        {"binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":165304,"sampleCount":1,"binaryName":"Halo","address":7170766264}]}]},
      "diagnosticMetaData":{"exceptionType":1,"signal":11,"osVersion":"iPhone OS 27.2","deviceType":"iPhone17,3","pid":42,
        "terminationReason":"Namespace SIGNAL, Code 0xb",
        "objectiveCexceptionReason":{"exceptionName":"NSRangeException","className":"NSException","exceptionType":"NSRangeException",
          "composedMessage":"no row for dinner at eight","formatString":"no row for %@","arguments":["dinner at eight"]}}}],
     "hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"2 sec","note":"@alice:example.org in !abc:example.org saw https://example.org/x"}}]}
    """#.utf8)

    @Test("A payload is stored and comes back")
    func roundTrip() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricPayloadStore(directory: directory)
        #expect(store.save(crash, kind: .diagnostics, at: now))
        #expect(store.save(payload(), kind: .metrics, at: now.addingTimeInterval(1)))
        let stored = store.all(now: now.addingTimeInterval(2))
        #expect(stored.map { $0.filename.contains("diagnostics") } == [true, false])
        let first = try #require(stored.first)
        let object = try #require(try JSONSerialization.jsonObject(with: first.data) as? [String: Any])
        let text = String(decoding: first.data, as: UTF8.self)
        #expect((object["crashDiagnostics"] as? [Any])?.count == 1)
        for kept in ["70B89F27-1634-3580-A695-57CDB41D7743", "165304", "NSRangeException", "iPhone17,3", "2 sec", "Code 0xb"] { #expect(text.contains(kept)) }
    }

    @Test("No message text, Matrix identifier or link is kept")
    func redaction() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricPayloadStore(directory: directory)
        store.save(crash, kind: .diagnostics, at: now)
        store.save(payload("$0123456789abcdefghijABCDEFGHIJ_-0123456789a #room:b.example mxc://b.example/x matrix:u/bob:b.example"), kind: .metrics, at: now)
        let text = store.all(now: now).map { String(decoding: $0.data, as: UTF8.self) }.joined()
        for secret in ["dinner", "alice", "!abc", "example", "0123456789abcdef", "bob", "#room"] { #expect(!text.contains(secret), "\(secret)") }
    }

    @Test("Old payloads, then the oldest over the count and size limits, are removed")
    func limits() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricPayloadStore(directory: directory, limits: .init(age: 100, count: 3, totalBytes: 10_000, payloadBytes: 4_000))
        for second in 0..<5 { store.save(payload("p\(second)"), kind: .metrics, at: now.addingTimeInterval(Double(second))) }
        #expect(store.all(now: now.addingTimeInterval(5)).map { String(decoding: $0.data, as: UTF8.self) } == (2..<5).map { #"{"note":"p\#($0)"}"# })
        #expect(store.all(now: now.addingTimeInterval(104)).count == 1)
        #expect(store.all(now: now.addingTimeInterval(500)).isEmpty)

        let large = String(repeating: "a", count: 3_500)
        for second in 600..<604 { store.save(payload(large), kind: .metrics, at: now.addingTimeInterval(Double(second))) }
        #expect(store.all(now: now.addingTimeInterval(604)).count == 2)
        #expect(!store.save(payload(String(repeating: "a", count: 5_000)), kind: .metrics, at: now.addingTimeInterval(605)))
    }

    @Test("Something that isn't a JSON object is refused and creates nothing")
    func notJSON() {
        let store = MetricPayloadStore(directory: directory)
        #expect(!store.save(Data("not json".utf8), kind: .metrics, at: now))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.all(now: now).isEmpty)
    }

    @Test("The folder stays out of backups")
    func backup() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        MetricPayloadStore(directory: directory).save(payload(), kind: .metrics, at: now)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}
