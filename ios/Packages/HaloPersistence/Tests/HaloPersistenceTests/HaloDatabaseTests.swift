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
        #expect(applied == ["v1-meta", "v2-read-intent", "v3-draft", "v4-audit-event", "v5-bot-task", "v6-bot-task-source-redacted", "v7-notification-record", "v8-read-intent-order"])
    }

    @Test("opening with file protection succeeds (the simulator and macOS don't report protection classes, so the class itself is checked on a device)")
    func protects() throws {
        let file = path()
        _ = try HaloDatabase(path: file)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("an unusable path is a storage error, not a crash")
    func badPath() {
        #expect(throws: HaloError.storage(.migrationFailed)) { try HaloDatabase(path: "/nonexistent-dir/x.sqlite") }
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
