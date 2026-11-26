import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// Signing other sessions out against a real server (M18-13): `infra/test/run.sh devices`.
@Suite("Sign out other sessions", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh devices"))
struct DevicesContractTests {
    @Test("Other sessions are signed out with the password; a wrong password and this device are refused", .timeLimit(.minutes(3)))
    func signOutOthers() async throws {
        let me = try await signIn("this phone")
        let first = try await signIn("old phone")
        let second = try await signIn("old laptop")
        let port = MatrixDevicesPort(session: me)
        #expect(await port.canSignOutOthers())

        let before = try await port.devices()
        #expect(before[0].isCurrent && before[0].displayName == "this phone")  // the server may list further nameless sessions
        let firstID = try #require(before.first { $0.displayName == "old phone" }?.id)
        let secondID = try #require(before.first { $0.displayName == "old laptop" }?.id)

        await #expect(throws: HaloError.invalidInput("CURRENT_PASSWORD")) { try await port.signOut(devices: [firstID], password: "not the password") }
        #expect(try await port.devices().count == before.count, "a wrong password signs nothing out")
        await #expect(throws: HaloError.invalidInput("CURRENT_DEVICE")) { try await port.signOut(devices: [before[0].id], password: env["HALO_FAULT_PASSWORD"] ?? "") }

        try await port.signOut(devices: [firstID], password: env["HALO_FAULT_PASSWORD"] ?? "")
        #expect(try await port.devices().map(\.id).contains(firstID) == false)
        try await port.signOut(devices: [secondID], password: env["HALO_FAULT_PASSWORD"] ?? "")
        let after = try await port.devices()
        #expect(after.count == before.count - 2 && after[0].isCurrent, "the two named sessions are gone, this device is left")
        #expect(Set(after.compactMap(\.displayName)) == ["this phone"])
        _ = (first, second)
    }

    private func signIn(_ device: String) async throws -> MatrixSessionPort {
        let session = MatrixSessionPort(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("halo-devices-\(UUID().uuidString)"))
        let details = try await session.loginDetails(server: env["HALO_FAULT_DIRECT"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_FAULT_USER"] ?? "", password: env["HALO_FAULT_PASSWORD"] ?? "", deviceDisplayName: device), on: details)
        Cleanup.current.add { try? await session.logout() }
        return session
    }
}
