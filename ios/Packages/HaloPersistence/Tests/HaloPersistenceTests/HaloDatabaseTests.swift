import Foundation
import GRDB
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("HaloDatabase")
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
        #expect(applied == ["v1-meta", "v2-read-intent"])
    }

    @Test("an unusable path is a storage error, not a crash")
    func badPath() {
        #expect(throws: HaloError.storage(.migrationFailed)) { try HaloDatabase(path: "/nonexistent-dir/x.sqlite") }
    }
}
