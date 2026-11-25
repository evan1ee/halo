import Foundation
import GRDB
import HaloFoundation

/// Halo's database (docs/data/PERSISTENCE.md). Opens a WAL `DatabasePool` and applies the append-only
/// migrations (docs/data/MIGRATIONS.md). M1 has no tables yet; the first migration arrives with the first store.
public struct HaloDatabase: Sendable {
    let pool: DatabasePool

    /// - Parameters:
    ///   - path: the database file; its directory must exist.
    ///   - observesSuspensionNotifications: subscribes to GRDB's `Database.suspendNotification` / `resumeNotification`
    ///     so the pool acquires no SQLite locks while iOS suspends the process (prevents `0xdead10cc`, R-25 / V-SQL-2).
    public init(path: String, observesSuspensionNotifications: Bool = true) throws(HaloError) {
        do {
            var configuration = Configuration()
            configuration.label = "halo.sqlite"
            configuration.busyMode = .timeout(5)
            configuration.observesSuspensionNotifications = observesSuspensionNotifications
            pool = try DatabasePool(path: path, configuration: configuration)
            try Self.migrator.migrate(pool)
        } catch {
            throw Self.failure(of: error)
        }
        try Self.protect(path: path)
    }

    /// How a database was opened by `openRecovering`.
    public enum Opened: Sendable, Equatable {
        case clean
        /// The file was damaged or couldn't be migrated: it was kept at `keptCopy` and a new, empty database made (AC-REL-5).
        /// What was only in it is lost: drafts, read receipts not yet sent, notification records, bot tasks.
        case recovered(keptCopy: URL)
    }

    /// Opens the database; if the file is damaged (or a migration can't run on it), keeps it as `<name>.damaged` (replacing an
    /// earlier copy) and starts a new one, so the app never loops on an unopenable file. A file that is only locked or
    /// unreadable for now (before first unlock, disk full) is left alone and reported as `.storage(.unavailable)`.
    public static func openRecovering(path: String, observesSuspensionNotifications: Bool = true) throws(HaloError) -> (HaloDatabase, Opened) {
        do {
            return (try HaloDatabase(path: path, observesSuspensionNotifications: observesSuspensionNotifications), .clean)
        } catch {
            guard error == .storage(.corrupted) || error == .storage(.migrationFailed) else { throw error }
            let manager = FileManager.default
            let kept = URL(fileURLWithPath: path + ".damaged")
            try? manager.removeItem(at: kept)
            do { try manager.moveItem(atPath: path, toPath: kept.path) } catch { throw .storage(.corrupted) }
            for suffix in ["-wal", "-shm"] { try? manager.removeItem(atPath: path + suffix) }
            return (try HaloDatabase(path: path, observesSuspensionNotifications: observesSuspensionNotifications), .recovered(keptCopy: kept))
        }
    }

    /// Only a damaged file or a migration that can't run is `corrupted` / `migrationFailed`; a file that is busy, locked, on a
    /// full disk or unreadable until the first unlock is `unavailable` and must not be thrown away.
    static func failure(of error: any Error) -> HaloError {
        guard let error = error as? DatabaseError else { return .storage(.migrationFailed) }
        switch error.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB: return .storage(.corrupted)
        case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_FULL, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_NOMEM, .SQLITE_AUTH, .SQLITE_PROTOCOL:
            return .storage(.unavailable)
        default: return .storage(.migrationFailed)
        }
    }

    /// Suspends all open `HaloDatabase` pools in this process so SQLite acquires no new locks while iOS suspends
    /// the app in the shared App Group container (R-25 / V-SQL-2, prevents `0xdead10cc`).
    public static func suspendAll() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Resumes all open `HaloDatabase` pools in this process when returning to the foreground (R-25).
    public static func resumeAll() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Sets `completeUntilFirstUserAuthentication` on the database and its WAL/shared-memory files, and on the
    /// directory so files SQLite creates later inherit it (PERSISTENCE §3: the NSE must read it while locked).
    static func protect(path: String) throws(HaloError) {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        do {
            for item in [directory, path, path + "-wal", path + "-shm"] where manager.fileExists(atPath: item) {
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: item)
            }
        } catch { throw .storage(.corrupted) }
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
        migrator.registerMigration("v3-draft") { db in
            try db.execute(sql: """
                CREATE TABLE draft (
                  account TEXT NOT NULL, room_id TEXT NOT NULL, body TEXT NOT NULL, updated_at INTEGER NOT NULL,
                  PRIMARY KEY (account, room_id)
                )
                """)
        }
        migrator.registerMigration("v4-audit-event") { db in
            try db.execute(sql: """
                CREATE TABLE audit_event (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, at INTEGER NOT NULL,
                  room_hash TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('explained','unexplained')),
                  reason TEXT NOT NULL, inputs_json TEXT NOT NULL, app_version TEXT NOT NULL
                )
                """)
        }
        migrator.registerMigration("v5-bot-task") { db in
            try db.execute(sql: """
                CREATE TABLE bot_task (
                  account TEXT NOT NULL, room_id TEXT NOT NULL, bot_sender TEXT NOT NULL,
                  entity_type TEXT NOT NULL CHECK (entity_type IN ('todo','reminder')), entity_id TEXT NOT NULL,
                  source_event_id TEXT, title TEXT, detail TEXT,
                  status TEXT NOT NULL CHECK (status IN ('open','completed','deleted')),
                  as_of_ts INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                  PRIMARY KEY (account, room_id, bot_sender, entity_type, entity_id)
                )
                """)
        }
        migrator.registerMigration("v6-bot-task-source-redacted") { db in
            try db.execute(sql: "ALTER TABLE bot_task ADD COLUMN source_redacted INTEGER NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("v7-notification-record") { db in
            try db.execute(sql: """
                CREATE TABLE notification_record (
                  account TEXT NOT NULL, event_id TEXT NOT NULL, room_id TEXT NOT NULL,
                  event_ts INTEGER NOT NULL, is_mention INTEGER NOT NULL, delivered_at INTEGER NOT NULL,
                  source TEXT NOT NULL CHECK (source IN ('nse','app')),
                  PRIMARY KEY (account, event_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX notification_record_room ON notification_record(account, room_id, event_ts)")
        }
        migrator.registerMigration("v8-read-intent-order") { db in
            try db.execute(sql: "ALTER TABLE read_intent ADD COLUMN timeline_order INTEGER NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("v9-bot-action") { db in
            try db.execute(sql: """
                CREATE TABLE bot_action (
                  account TEXT NOT NULL, room_id TEXT NOT NULL, bot_sender TEXT NOT NULL,
                  item_id TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','no_response')),
                  updated_at INTEGER NOT NULL,
                  PRIMARY KEY (account, room_id, bot_sender, item_id)
                )
                """)
        }
        return migrator
    }
}
