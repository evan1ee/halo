import Foundation
import GRDB
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("HaloDatabase", .serialized)
struct HaloDatabaseTests {
    private func path() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("halo-\(UUID().uuidString).sqlite").path
    }

    @Test("opens, migrates once, and reopening an existing database keeps its schema")
    func migrates() throws {
        let file = path()
        let first = try HaloDatabase(path: file)
        #expect(try first.sqliteVersion().isEmpty == false)
        let tables = try first.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='halo_meta'") }
        #expect(tables == ["halo_meta"])
        let second = try HaloDatabase(path: file)
        let applied = try second.pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == ["v1-meta", "v2-read-intent", "v3-draft", "v4-audit-event", "v5-bot-task", "v6-bot-task-source-redacted", "v7-notification-record", "v8-read-intent-order", "v9-bot-action"])
    }

    @Test("opening with file protection succeeds (the simulator and macOS don't report protection classes, so the class itself is checked on a device)")
    func protects() throws {
        let file = path()
        _ = try HaloDatabase(path: file)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("an unusable path is a storage error that may pass, not a crash and not a reason to delete anything")
    func badPath() {
        #expect(throws: HaloError.storage(.unavailable)) { try HaloDatabase(path: "/nonexistent-dir/x.sqlite") }
        #expect(throws: HaloError.storage(.unavailable)) { try HaloDatabase.openRecovering(path: "/nonexistent-dir/x.sqlite") }
    }

    @Test("a damaged file is kept as .damaged and replaced by a new database; the next open is clean (AC-REL-5)")
    func recoversDamagedFile() throws {
        let file = path()
        defer { for suffix in ["", "-wal", "-shm", ".damaged"] { try? FileManager.default.removeItem(atPath: file + suffix) } }
        let garbage = Data(repeating: 0x41, count: 8192)
        try garbage.write(to: URL(fileURLWithPath: file))

        do {
            let (database, opened) = try HaloDatabase.openRecovering(path: file)
            guard case .recovered(let kept) = opened else { Issue.record("expected a recovery, got \(opened)"); return }
            #expect(kept.path == file + ".damaged")
            #expect(try Data(contentsOf: kept) == garbage, "the damaged file is kept untouched")
            let tables = try database.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE name='draft'") }
            #expect(tables == ["draft"], "the new database is migrated and usable")
        }
        do {
            let (_, again) = try HaloDatabase.openRecovering(path: file)
            #expect(again == .clean)
        }

        // A second damage (the app is closed, so no -wal or -shm of the earlier pool is left) replaces the earlier copy.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file + suffix) }
        try garbage.prefix(100).write(to: URL(fileURLWithPath: file))
        let (_, second) = try HaloDatabase.openRecovering(path: file)
        guard case .recovered(let secondKept) = second else { Issue.record("expected a second recovery"); return }
        #expect(try Data(contentsOf: secondKept).count == 100)
    }

    @Test("only damage is recovered: busy, locked, full and unreadable files are left alone")
    func failureClasses() {
        func code(_ result: ResultCode) -> HaloError { HaloDatabase.failure(of: DatabaseError(resultCode: result)) }
        #expect(code(.SQLITE_CORRUPT) == .storage(.corrupted))
        #expect(code(.SQLITE_NOTADB) == .storage(.corrupted))
        for transient in [ResultCode.SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_FULL, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_AUTH] {
            #expect(code(transient) == .storage(.unavailable), "\(transient)")
        }
        #expect(code(.SQLITE_CONSTRAINT) == .storage(.migrationFailed))
        #expect(HaloDatabase.failure(of: CancellationError()) == .storage(.migrationFailed))
    }

    @Test("upgrade from every released schema: the migrations are append-only and keep what each version stored (AC-REL-5)")
    func upgradesFromEverySchema() throws {
        // Frozen: a registered migration is never edited or reordered (MIGRATIONS §1). A new one is added at the end, here too.
        let identifiers = HaloDatabase.migrator.migrations
        #expect(identifiers == ["v1-meta", "v2-read-intent", "v3-draft", "v4-audit-event", "v5-bot-task", "v6-bot-task-source-redacted", "v7-notification-record", "v8-read-intent-order", "v9-bot-action"])
        for (index, version) in identifiers.enumerated() {
            let file = path()
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file + suffix) } }
            // The database as that version left it, with a row in each table that version has.
            let old = try DatabasePool(path: file)
            try HaloDatabase.migrator.migrate(old, upTo: version)
            let tables = try old.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
            try old.write { db in
                if tables.contains("draft") {
                    try db.execute(sql: "INSERT INTO draft (account, room_id, body, updated_at) VALUES ('a', '!r:x', 'hello', 1)")
                }
                if tables.contains("read_intent") {
                    try db.execute(sql: """
                        INSERT INTO read_intent (account, room_id, event_id, event_ts, created_at, state, receipt_type)
                        VALUES ('a', '!r:x', '$e', 5, 2, 'pending', 'read')
                        """)
                }
            }
            try old.close()

            let database = try HaloDatabase(path: file)
            let applied = try database.pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
            #expect(applied == identifiers, "from \(version) (\(index + 1) of \(identifiers.count))")
            if tables.contains("draft") {
                #expect(try database.pool.read { try String.fetchOne($0, sql: "SELECT body FROM draft WHERE room_id='!r:x'") } == "hello", "draft from \(version)")
            }
            if tables.contains("read_intent") {
                #expect(try database.pool.read { try String.fetchOne($0, sql: "SELECT event_id FROM read_intent WHERE room_id='!r:x'") } == "$e", "read intent from \(version)")
            }
        }
    }

    @Test("R-25: suspension stops new SQLite writes until resumed (prevents 0xdead10cc in shared App Group)")
    func suspendsAndResumes() throws {
        let db = try HaloDatabase(path: path())
        #expect(db.pool.configuration.observesSuspensionNotifications == true)
        defer { HaloDatabase.resumeAll() }

        HaloDatabase.suspendAll()
        #expect(throws: (any Error).self) {
            try db.pool.write { conn in
                try conn.execute(sql: "INSERT OR REPLACE INTO halo_meta (key, value) VALUES ('k', 'suspended')")
            }
        }

        HaloDatabase.resumeAll()
        try db.pool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO halo_meta (key, value) VALUES ('k', 'resumed')")
        }
        let value = try db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM halo_meta WHERE key = 'k'") }
        #expect(value == "resumed")
    }
}
