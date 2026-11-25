import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// A damaged or unopenable SDK store never loops and never loses the account silently (AC-REL-5): `infra/test/run.sh store`.
@Suite("Store recovery", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh store"))
struct StoreRecoveryContractTests {
    private func signIn() async throws -> (StoredSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-store-\(UUID().uuidString)")
        let session = MatrixSessionPort(baseDirectory: directory)
        let details = try await session.loginDetails(server: env["HALO_FAULT_DIRECT"] ?? "")
        let stored = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_FAULT_USER"] ?? "", password: env["HALO_FAULT_PASSWORD"] ?? "", deviceDisplayName: "store"), on: details)
        try await session.startSync()
        try await Task.sleep(for: .seconds(2))
        await session.stopSync()
        Cleanup.current.add { try? await session.logout() }
        return (stored, directory)
    }

    private func databases(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "sqlite3" || $0.lastPathComponent.hasSuffix(".sqlite3-wal") }
    }

    @Test("a store of garbage files is reported as damaged, not as a failure that may pass; signing in again works (AC-REL-5)", .timeLimit(.minutes(3)))
    func garbage() async throws {
        let (stored, directory) = try await signIn()
        let files = databases(in: directory)
        #expect(files.count >= 4)
        for file in files { try Data(repeating: 0x41, count: 4096).write(to: file) }
        let again = MatrixSessionPort(baseDirectory: directory)
        await #expect(throws: HaloError.storage(.corrupted)) { try await again.restore(stored) }
        // The reset path: sign out (nothing to tell the server from a client that never started), then sign in as a new device.
        try? await again.logout()
        let fresh = MatrixSessionPort(baseDirectory: directory)
        let details = try await fresh.loginDetails(server: env["HALO_FAULT_DIRECT"] ?? "")
        let second = try await fresh.loginPassword(
            PasswordCredentials(username: env["HALO_FAULT_USER"] ?? "", password: env["HALO_FAULT_PASSWORD"] ?? "", deviceDisplayName: "store-again"), on: details)
        #expect(second.deviceID != stored.deviceID)
        Cleanup.current.add { try? await fresh.logout() }
    }

    @Test("a wrong store passphrase is reported as damaged too", .timeLimit(.minutes(3)))
    func wrongPassphrase() async throws {
        let (stored, directory) = try await signIn()
        var payload = try #require(try JSONSerialization.jsonObject(with: stored.payload) as? [String: Any])
        payload["passphrase"] = "not-the-passphrase"
        let changed = StoredSession(userID: stored.userID, deviceID: stored.deviceID, payload: try JSONSerialization.data(withJSONObject: payload))
        let again = MatrixSessionPort(baseDirectory: directory)
        await #expect(throws: HaloError.storage(.corrupted)) { try await again.restore(changed) }
    }

    @Test("an intact store restores, so the damage check doesn't fire on a healthy one", .timeLimit(.minutes(3)))
    func healthy() async throws {
        let (stored, directory) = try await signIn()
        let again = MatrixSessionPort(baseDirectory: directory)
        try await again.restore(stored)
        await again.stopSync()
    }
}
