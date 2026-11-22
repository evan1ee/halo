import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("AuditEventStore")
struct AuditEventStoreTests {
    private func store(_ account: String = "@a:x.org", database: HaloDatabase? = nil) throws -> (AuditEventStore, HaloDatabase) {
        let db = try database ?? HaloDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path, observesSuspensionNotifications: false)
        return (AuditEventStore(database: db, account: try UserID(account)), db)
    }
    private func event(_ n: Int, kind: AuditKind = .explained) -> AuditEvent {
        AuditEvent(at: Date(timeIntervalSince1970: Double(n)), roomHash: "!r\(n)", finding: AuditFinding(kind: kind, reason: "R\(n)"), inputsJSON: "{}", appVersion: "1")
    }

    @Test("events round trip in order and unexplained ones are counted per account")
    func roundTrip() async throws {
        let (a, db) = try store()
        let (b, _) = try store("@b:x.org", database: db)
        try await a.append([event(1), event(2, kind: .unexplained)])
        try await b.append([event(3, kind: .unexplained)])
        #expect(try await a.all().map(\.roomHash) == ["!r1", "!r2"])
        #expect(try await a.all().last?.finding == AuditFinding(kind: .unexplained, reason: "R2"))
        #expect(try await a.unexplainedCount() == 1)
        #expect(try await b.unexplainedCount() == 1)
    }

    @Test("at most 5,000 rows are kept; the oldest go first")
    func capacity() async throws {
        let (store, _) = try store()
        try await store.append((1...4_990).map { event($0) })
        try await store.append((4_991...5_010).map { event($0) })
        let all = try await store.all()
        #expect(all.count == AuditEventStore.capacity)
        #expect(all.first?.roomHash == "!r11" && all.last?.roomHash == "!r5010")
    }
}
