import Foundation
import GRDB
import HaloDomain
import HaloFoundation

/// `AuditEventPort` over `audit_event` (docs/data/DATA_MODELS.md): at most `capacity` rows per account, oldest pruned first.
public struct AuditEventStore: AuditEventPort {
    public static let capacity = 5_000
    private let database: HaloDatabase
    private let account: String

    public init(database: HaloDatabase, account: UserID) {
        self.database = database
        self.account = account.rawValue
    }

    public func append(_ events: [AuditEvent]) async throws(HaloError) {
        guard !events.isEmpty else { return }
        do {
            let account = account
            try await database.pool.write { db in
                for event in events {
                    try db.execute(
                        sql: "INSERT INTO audit_event (account, at, room_hash, kind, reason, inputs_json, app_version) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        arguments: [
                            account, Int64((event.at.timeIntervalSince1970 * 1000).rounded()), event.roomHash, event.finding.kind.rawValue,
                            event.finding.reason, event.inputsJSON, event.appVersion,
                        ])
                }
                try db.execute(
                    sql: """
                        DELETE FROM audit_event WHERE account = ? AND id NOT IN
                          (SELECT id FROM audit_event WHERE account = ? ORDER BY id DESC LIMIT ?)
                        """,
                    arguments: [account, account, Self.capacity])
            }
        } catch { throw .storage(.corrupted) }
    }

    public func all() async throws(HaloError) -> [AuditEvent] {
        do {
            let account = account
            return try await database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT at, room_hash, kind, reason, inputs_json, app_version FROM audit_event WHERE account = ? ORDER BY id", arguments: [account])
                    .map { row in
                        AuditEvent(
                            at: Date(timeIntervalSince1970: Double(row["at"] as Int64) / 1000), roomHash: row["room_hash"],
                            finding: AuditFinding(kind: (row["kind"] as String) == "explained" ? .explained : .unexplained, reason: row["reason"]),
                            inputsJSON: row["inputs_json"], appVersion: row["app_version"])
                    }
            }
        } catch { throw .storage(.corrupted) }
    }

    public func unexplainedCount() async throws(HaloError) -> Int {
        do {
            let account = account
            return try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_event WHERE account = ? AND kind = 'unexplained'", arguments: [account]) ?? 0
            }
        } catch { throw .storage(.corrupted) }
    }
}
