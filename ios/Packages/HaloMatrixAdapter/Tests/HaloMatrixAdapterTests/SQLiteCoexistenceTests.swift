import Foundation
import HaloDomain
import HaloFoundation
import HaloPersistence
import Testing
@testable import HaloMatrixAdapter

/// V-SQL-1: the SDK's bundled SQLite (private symbols inside the framework) and Halo's GRDB database work in one
/// process without interfering. The SDK side needs a homeserver (same variables as the contracts).
private let env = ProcessInfo.processInfo.environment
private let configured = env["HALO_DEV_SERVER"] != nil && env["HALO_DEV_USER"] != nil && env["HALO_DEV_PASSWORD"] != nil

@Suite("SQLite coexistence (V-SQL-1)", .serialized)
struct SQLiteCoexistenceTests {
    @Test("Halo's database opens and migrates in the iOS test host")
    func databaseAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let database = try HaloDatabase(path: dir.appendingPathComponent("halo.sqlite").path)
        #expect(try database.sqliteVersion().isEmpty == false)
    }

    @Test("an SDK client with its SQLite store, syncing, and Halo's database run side by side", .enabled(if: configured, "needs HALO_DEV_*"))
    func sideBySide() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-vsql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = MatrixSessionPort(baseDirectory: dir)
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "vsql"),
            on: details)
        let sync = MatrixSyncPort(session: session)
        try await sync.start()  // the SDK is now reading and writing its own SQLite store

        let database = try HaloDatabase(path: dir.appendingPathComponent("halo.sqlite").path)
        let version = try database.sqliteVersion()
        #expect(!version.isEmpty)
        for _ in 0..<5 { _ = try database.sqliteVersion() }  // GRDB keeps working while sync runs

        await sync.stop()
        try await session.logout()
    }
}
