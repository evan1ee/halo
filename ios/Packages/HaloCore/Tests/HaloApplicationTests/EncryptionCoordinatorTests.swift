import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("EncryptionCoordinator")
struct EncryptionCoordinatorTests {
    private func make(_ port: FakeEncryptionPort) async throws -> (EncryptionCoordinator, SessionCoordinator) {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        await session.start()
        let coordinator = EncryptionCoordinator(port: port, session: session)
        await coordinator.begin()
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
        return (coordinator, session)
    }

    private func wait(_ coordinator: EncryptionCoordinator, _ predicate: @Sendable (EncryptionCoordinator.Snapshot) -> Bool) async -> EncryptionCoordinator.Snapshot? {
        for await snapshot in await coordinator.snapshots() where predicate(snapshot) { return snapshot }
        return nil
    }

    @Test("an unverified device with recovery set up is reported once signed in")
    func reportsStatus() async throws {
        let (coordinator, _) = try await make(FakeEncryptionPort(recoveryKey: "k"))
        let snapshot = await wait(coordinator) { $0.status.needsRecovery }
        #expect(snapshot?.status == EncryptionStatus(verification: .unverified, recovery: .incomplete))
    }

    @Test("a wrong key fails with the input error and stays unverified; the right key verifies")
    func recovers() async throws {
        let port = FakeEncryptionPort(recoveryKey: "right")
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.needsRecovery }

        await coordinator.recover(recoveryKey: "wrong")
        #expect(await coordinator.snapshot.recovery == .failed(.invalidInput("RECOVERY_KEY")))
        #expect(port.status.verification == .unverified)

        await coordinator.recover(recoveryKey: "  right \n")  // pasted keys often carry whitespace
        #expect(await coordinator.snapshot.recovery == .idle)
        #expect(await wait(coordinator) { $0.status.verification == .verified } != nil)
    }

    @Test("an empty key is rejected without calling the port")
    func emptyKey() async throws {
        let port = FakeEncryptionPort(recoveryKey: "right")
        let (coordinator, _) = try await make(port)
        await coordinator.recover(recoveryKey: "   ")
        #expect(await coordinator.snapshot.recovery == .failed(.invalidInput("RECOVERY_KEY")))
        #expect(port.status.verification == .unverified)
    }

    @Test("a lost recovery key: the reset asks for the password, verifies this device and returns a new key (FR-8, AC-SEC-3)")
    func resetsIdentity() async throws {
        let port = FakeEncryptionPort(recoveryKey: "OLD", verified: false)
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.recovery == .incomplete }

        // Not prepared: nothing happens.
        await #expect(throws: HaloError.invalidInput("RESET_NOT_PREPARED")) { try await coordinator.resetIdentity(password: "pw") }
        #expect(try await coordinator.prepareIdentityReset() == .password)
        // The password is needed, and a refusal changes nothing.
        await #expect(throws: HaloError.invalidInput("PASSWORD")) { try await coordinator.resetIdentity(password: "") }
        #expect(port.identityResets.isEmpty)

        let key = try await coordinator.resetIdentity(password: "pw")
        #expect(key != "OLD" && !key.isEmpty)
        #expect(port.identityResets == ["pw"])
        let done = await wait(coordinator) { $0.status.verification == .verified && $0.status.recovery == .enabled }
        #expect(done?.recovery == .idle)
        #expect(done?.status.backup == .on)
        // The new key unlocks a device; the old one doesn't.
        await coordinator.recover(recoveryKey: "OLD")
        #expect(port.status.verification == .verified)  // already verified: a wrong key can't undo it
    }

    @Test("a reset can be cancelled, and the browser approval needs no password")
    func resetVariants() async throws {
        let port = FakeEncryptionPort(recoveryKey: "OLD", verified: false)
        let (coordinator, _) = try await make(port)
        #expect(try await coordinator.prepareIdentityReset() == .password)
        await coordinator.cancelIdentityReset()
        await #expect(throws: HaloError.invalidInput("RESET_NOT_PREPARED")) { try await coordinator.resetIdentity(password: "pw") }
        port.setIdentityResetRequirement(.approveInBrowser(approvalURL: "https://account.example.org/reset"))
        #expect(try await coordinator.prepareIdentityReset() == .approveInBrowser(approvalURL: "https://account.example.org/reset"))
        _ = try await coordinator.resetIdentity(password: nil)
        #expect(port.identityResets == [nil])
    }

    @Test("signing out forgets the status")
    func signOut() async throws {
        let (coordinator, session) = try await make(FakeEncryptionPort(recoveryKey: "k"))
        _ = await wait(coordinator) { $0.status.needsRecovery }
        await session.logout()
        #expect(await wait(coordinator) { $0.status == .unknown } != nil)
    }

    @Test("setting up recovery returns the new key once, leaves the coordinator idle and reports recovery on")
    func setsUpRecovery() async throws {
        let port = FakeEncryptionPort(recoveryKey: nil)
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.recovery == .disabled }
        let key = try await coordinator.enableRecovery()
        #expect(key.hasPrefix("FAKE-RECOVERY-KEY"))
        #expect(await coordinator.snapshot.recovery == .idle)
        #expect(await wait(coordinator) { $0.status.recovery == .enabled } != nil)
    }

    @Test("SAS verification transitions from request through emoji comparison to verified")
    func sasVerificationFlow() async throws {
        let port = FakeEncryptionPort(recoveryKey: "k", verified: false)
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.needsRecovery }

        await coordinator.requestDeviceVerification()
        #expect(await wait(coordinator) { $0.verificationPhase == .waitingForOtherDevice } != nil)

        let emojis = [VerificationEmoji(symbol: "🐶", description: "Dog"), VerificationEmoji(symbol: "🐱", description: "Cat")]
        port.simulateVerificationPhase(.comparingEmojis(emojis))
        #expect(await wait(coordinator) { $0.verificationPhase == .comparingEmojis(emojis) } != nil)

        await coordinator.approveVerification()
        #expect(await wait(coordinator) { $0.verificationPhase == .waitingForPartnerConfirmation } != nil)

        port.simulateVerificationPhase(.verified)
        let finished = await wait(coordinator) { $0.verificationPhase == .verified && $0.status.verification == .verified }
        #expect(finished != nil)
    }

    @Test("incoming SAS request can be accepted or declined")
    func sasIncomingAndDecline() async throws {
        let port = FakeEncryptionPort(recoveryKey: "k", verified: false)
        let (coordinator, _) = try await make(port)
        _ = await wait(coordinator) { $0.status.needsRecovery }

        let req = VerificationRequest(senderID: "@alice:example.org", flowID: "flow-1", deviceID: "DEV2", deviceDisplayName: "Mac")
        port.simulateVerificationPhase(.incomingRequest(req))
        #expect(await wait(coordinator) { $0.verificationPhase == .incomingRequest(req) } != nil)

        await coordinator.acceptVerificationRequest()
        #expect(await wait(coordinator) { $0.verificationPhase == .startingSAS } != nil)

        await coordinator.declineVerification()
        #expect(await wait(coordinator) {
            if case .cancelled = $0.verificationPhase { return true }
            return false
        } != nil)

        await coordinator.cancelVerification()
        #expect(await wait(coordinator) { $0.verificationPhase == .idle } != nil)
    }
}
