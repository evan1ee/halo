import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureOnboarding

@MainActor
@Suite("RecoveryViewModel identity reset")
struct RecoveryViewModelResetTests {
    private func make(_ port: FakeEncryptionPort) async throws -> RecoveryViewModel {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        await session.start()
        let model = RecoveryViewModel(coordinator: EncryptionCoordinator(port: port, session: session))
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
        return model
    }

    @Test("a lost key: the password is asked for, a wrong or missing one says so, and the new key is returned once (M18-3)")
    func reset() async throws {
        let port = FakeEncryptionPort(recoveryKey: "OLD", verified: false)
        let model = try await make(port)
        guard case .success(.password) = await model.prepareIdentityReset() else { Issue.record("expected a password prompt"); return }
        guard case .failure(let missing) = await model.resetIdentity(password: "") else { Issue.record("an empty password must fail"); return }
        #expect(missing.text == "Enter your account password.")
        port.failNext(with: .unauthorized(soft: false))
        guard case .failure(let wrong) = await model.resetIdentity(password: "nope") else { Issue.record("a wrong password must fail"); return }
        #expect(wrong.text.contains("Nothing was changed"))
        #expect(port.identityResets.isEmpty)
        guard case .success(.password) = await model.prepareIdentityReset() else { Issue.record("expected a password prompt again"); return }
        guard case .success(let key) = await model.resetIdentity(password: "pw") else { Issue.record("the reset should work"); return }
        #expect(!key.isEmpty && key != "OLD")
        #expect(port.status.verification == .verified)
    }

    @Test("the key backup is shown in plain words")
    func backupStatus() async throws {
        let model = try await make(FakeEncryptionPort(recoveryKey: "OLD", verified: true))
        model.apply(.init(status: EncryptionStatus(verification: .verified, recovery: .enabled, backup: .on), recovery: .idle))
        #expect(model.backupStatus == "On")
        model.apply(.init(status: EncryptionStatus(verification: .verified, recovery: .enabled, backup: .off), recovery: .idle))
        #expect(model.backupStatus == "Off")
        model.apply(.init(status: EncryptionStatus(verification: .verified, recovery: .enabled, backup: .working), recovery: .idle))
        #expect(model.backupStatus == "Updating…")
    }
}
