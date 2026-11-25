import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// A contact's changed identity against a real server (ENCRYPTION_AND_DEVICES FR-7, AC-SEC-1): `infra/test/run.sh identity`.
@Suite("Identity changes", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh identity"))
struct IdentityContractTests {
    @Test("A second account resets its identity: the alert appears, accepting ends it, a later reset shows it again", .timeLimit(.minutes(5)))
    func contactResetsIdentity() async throws {
        let alice = try await signIn(env["HALO_FAULT_USER"] ?? "", "alice")
        let bob = try await signIn((env["HALO_FAULT_USER"] ?? "") + "peer", "bob")
        try await alice.startSync()
        try await bob.startSync()
        // Bob has an identity (recovery creates the cross-signing keys), and invites Alice to an encrypted room.
        _ = try await MatrixEncryptionPort(session: bob).enableRecovery()
        let room = try await SearchServer(session: bob).makeRoom(encrypted: true)
        let bobID = try await bob.signedInClient().userId()
        try await SearchServer(session: bob).call("POST", "rooms/\(room.rawValue)/invite", ["user_id": try await alice.signedInClient().userId()])
        try await SearchStage.wait(60, "the invitation") { (try? await alice.room(room)) != nil }
        try await SearchServer(session: alice).call("POST", "rooms/\(room.rawValue)/join", [:])
        try await SearchStage.wait(60, "the room joined") { (try? await alice.room(room))?.membership() == .joined }

        let timeline = try await MatrixTimelinePort(session: alice).open(room: room)
        var alerts = Alerts(timeline.identityAlerts())
        // First sight of Bob's identity is trusted: nothing to show yet.
        try await Task.sleep(for: .seconds(3))
        #expect(alerts.current.isEmpty)

        let user = try UserID(bobID)
        try await resetIdentity(of: bob)
        try await SearchStage.wait(90, "the alert after Bob's reset") { alerts.current.map(\.user) == [user] }
        #expect(alerts.current.first?.kind == .changed)

        try await timeline.acceptIdentity(of: user)
        try await SearchStage.wait(30, "the alert to end") { alerts.current.isEmpty }

        // Not once and done: the next change is shown again.
        try await resetIdentity(of: bob)
        try await SearchStage.wait(90, "the alert after the second reset") { alerts.current.map(\.user) == [user] }
        await timeline.close()
    }

    private func signIn(_ user: String, _ device: String) async throws -> MatrixSessionPort {
        let session = MatrixSessionPort(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("halo-identity-\(UUID().uuidString)"))
        let details = try await session.loginDetails(server: env["HALO_FAULT_DIRECT"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: user, password: env["HALO_FAULT_PASSWORD"] ?? "", deviceDisplayName: device), on: details)
        Cleanup.current.add { try? await session.logout() }
        return session
    }

    /// Replaces the account's cross-signing identity, as "I lost my recovery key" does (M18-3), confirmed with the password.
    private func resetIdentity(of session: MatrixSessionPort) async throws {
        let handle = try await session.encryption().resetIdentity()
        let user = try await session.signedInClient().userId()
        guard let handle, case .uiaa(let info) = handle.authType() else { throw ContractViolation("expected a password prompt for the reset") }
        try await handle.reset(auth: .password(passwordDetails: AuthDataPasswordDetails(
            identifier: user, password: env["HALO_FAULT_PASSWORD"] ?? "", session: info.session)))
    }
}

/// The latest set an alert stream reported.
private struct Alerts {
    private let box = Latest()
    init(_ stream: AsyncStream<[IdentityAlert]>) {
        let box = box
        Task { for await alerts in stream { box.set(alerts) } }
    }
    var current: [IdentityAlert] { box.get() }

    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [IdentityAlert] = []
        func set(_ new: [IdentityAlert]) { lock.withLock { value = new } }
        func get() -> [IdentityAlert] { lock.withLock { value } }
    }
}
