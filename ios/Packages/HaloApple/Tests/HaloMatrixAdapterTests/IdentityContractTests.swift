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

    /// Replaces the account's cross-signing identity as "Lost your recovery key?" does (M18-3), confirmed with the password.
    @discardableResult
    private func resetIdentity(of session: MatrixSessionPort) async throws -> String {
        let port = MatrixEncryptionPort(session: session)
        guard try await port.prepareIdentityReset() == .password else { throw ContractViolation("expected a password prompt for the reset") }
        return try await port.resetIdentity(password: env["HALO_FAULT_PASSWORD"] ?? "")
    }

    @Test("Lost recovery key: the reset verifies the device, backs up again with a new key that unlocks a second device, and the old key stops working (M18-3, AC-E2EE-4)", .timeLimit(.minutes(4)))
    func lostRecoveryKey() async throws {
        let user = env["HALO_FAULT_USER"] ?? ""
        let first = try await signIn(user, "first")
        try await first.startSync()
        let firstPort = MatrixEncryptionPort(session: first)
        // The earlier test may have left a backup on this account; a new key then replaces it, as the app does.
        let oldKey: String
        do { oldKey = try await firstPort.enableRecovery() } catch { oldKey = try await firstPort.resetRecovery() }
        // A second device that can't be verified from the first, as when the phone is gone.
        let lost = try await signIn(user, "lost")
        try await lost.startSync()
        let status = await firstStatus(of: lost)
        #expect(status.verification == .unverified)

        let newKey = try await resetIdentity(of: lost)
        #expect(newKey != oldKey)
        let after = await firstStatus(of: lost, until: { $0.verification == .verified && $0.recovery == .enabled })
        #expect(after.verification == .verified && after.recovery == .enabled)
        let backup = await firstStatus(of: lost, until: { $0.backup != .unknown }).backup
        #expect(backup == .on, "the key backup is on again after the reset")

        // The new key unlocks a third device; the old one doesn't.
        let third = try await signIn(user, "third")
        try await third.startSync()
        let thirdPort = MatrixEncryptionPort(session: third)
        await #expect(throws: HaloError.self) { try await thirdPort.recover(recoveryKey: oldKey) }
        try await thirdPort.recover(recoveryKey: newKey)
        try await SearchStage.wait(60, "the third device to be verified") { await firstStatus(of: third).verification == .verified }
    }

    private func firstStatus(of session: MatrixSessionPort, until done: (EncryptionStatus) -> Bool = { _ in true }) async -> EncryptionStatus {
        let port = MatrixEncryptionPort(session: session)  // kept alive: the stream only follows while the port exists
        for await status in port.statuses() where status.verification != .unknown && done(status) { return status }
        return .unknown
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
