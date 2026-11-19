import Foundation
import GRDB
import HaloFoundation

/// Halo's database (docs/data/PERSISTENCE.md). Opens a WAL `DatabasePool` and applies the append-only
/// migrations (docs/data/MIGRATIONS.md). M1 has no tables yet; the first migration arrives with the first store.
public struct HaloDatabase: Sendable {
    let pool: DatabasePool

    /// - Parameter path: the database file; its directory must exist.
    public init(path: String) throws(HaloError) {
        do {
            var configuration = Configuration()
            configuration.label = "halo.sqlite"
            pool = try DatabasePool(path: path, configuration: configuration)
            try Self.migrator.migrate(pool)
        } catch {
            throw .storage(.migrationFailed)
        }
    }

    /// The SQLite library GRDB runs on, e.g. `3.51.0`. Used by diagnostics and the V-SQL-1 check.
    public func sqliteVersion() throws(HaloError) -> String {
        do {
            return try pool.read { try String.fetchOne($0, sql: "SELECT sqlite_version()") } ?? ""
        } catch { throw .storage(.corrupted) }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Append-only: never edit a registered migration (MIGRATIONS §1). v1 creates the schema bookkeeping table
        // that later migrations extend.
        migrator.registerMigration("v1-meta") { db in
            try db.create(table: "halo_meta") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2-read-intent") { db in
            try db.execute(sql: """
                CREATE TABLE read_intent (
                  account TEXT NOT NULL, room_id TEXT NOT NULL,
                  event_id TEXT NOT NULL, event_ts INTEGER NOT NULL,
                  created_at INTEGER NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','sent')),
                  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
                  receipt_type TEXT NOT NULL CHECK (receipt_type IN ('read','read_private')),
                  PRIMARY KEY (account, room_id)
                )
                """)
        }
        return migrator
    }
}
