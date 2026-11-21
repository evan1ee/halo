import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureAuth

@MainActor
@Suite("AuthViewModel")
struct AuthViewModelTests {
    @Test("a wrong password stays on the credentials screen with a message, and the password field is cleared")
    func wrongPassword() async throws {
        let port = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        port.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        port.addAccount(.init(localpart: "alice", password: "right"))
        let model = AuthViewModel(coordinator: SessionCoordinator(port: port, keychain: InMemoryKeychain()))

        model.apply(.signedOut(failure: nil))
        #expect(model.screen == .server)
        model.apply(.choosingMethod(ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true), failure: .unauthorized(soft: false)))
        #expect(model.screen == .credentials(host: "example.org"))
        #expect(model.errorMessage?.contains("Wrong username or password") == true)

        model.password = "wrong"
        await model.submitCredentials()
        #expect(model.password.isEmpty)
    }

    @Test("states map to screens; messages never contain server text or raw codes for known errors")
    func mapping() {
        let model = AuthViewModel(coordinator: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()))
        model.apply(.restoreFailed(.storage(.unavailable)))
        #expect(model.screen == .restoreFailed)
        #expect(model.errorMessage?.contains("Unlock") == true)
        model.apply(.signedOut(failure: .unsupported("NO_SLIDING_SYNC")))
        #expect(model.errorMessage?.contains("sync") == true)
        model.apply(.discovering)
        #expect(model.screen == .busy)
    }

    @Test("a new attempt clears the previous error while busy")
    func busyClearsError() {
        let model = AuthViewModel(coordinator: SessionCoordinator(port: FakeSessionPort(), keychain: InMemoryKeychain()))
        model.apply(.signedOut(failure: .invalidInput("SERVER_NAME")))
        #expect(model.errorMessage != nil)
        model.apply(.discovering)
        #expect(model.screen == .busy && model.errorMessage == nil)
    }

    @Test("the full flow against the fake ends signed in")
    func fullFlow() async throws {
        let port = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        port.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        port.addAccount(.init(localpart: "alice", password: "right"))
        let model = AuthViewModel(coordinator: SessionCoordinator(port: port, keychain: InMemoryKeychain()))
        await model.start()
        model.server = "example.org"
        await model.submitServer()
        model.username = "alice"
        model.password = "right"
        await model.submitCredentials()
        for _ in 0..<200 where model.screen != .signedIn { await Task.yield() }
        #expect(model.screen == .signedIn)
    }

    @Test("blank inputs keep submit disabled; changeServer returns to the server screen and clears password")
    func validationAndChangeServer() async throws {
        let port = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        port.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        let model = AuthViewModel(coordinator: SessionCoordinator(port: port, keychain: InMemoryKeychain()))
        await model.start()
        #expect(!model.canSubmitServer)
        model.server = "   "
        #expect(!model.canSubmitServer)
        model.server = "example.org"
        #expect(model.canSubmitServer)
        await model.submitServer()
        for _ in 0..<200 where model.screen != .credentials(host: "example.org") { await Task.yield() }
        #expect(model.screen == .credentials(host: "example.org"))
        #expect(!model.canSubmitCredentials)
        model.username = "alice"
        #expect(!model.canSubmitCredentials)
        model.password = "secret"
        #expect(model.canSubmitCredentials)
        await model.changeServer()
        for _ in 0..<200 where model.screen != .server { await Task.yield() }
        #expect(model.screen == .server && model.password.isEmpty && model.errorMessage == nil)
    }
}

@MainActor
@Suite("RecoveryViewModel")
struct RecoveryViewModelTests {
    private func model(_ port: FakeEncryptionPort) async throws -> RecoveryViewModel {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        let model = RecoveryViewModel(coordinator: EncryptionCoordinator(port: port, session: session))
        await model.start()
        await session.start()
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
        return model
    }

    @Test("the banner appears for an unverified device and the key field is cleared on submit")
    func flow() async throws {
        let model = try await model(FakeEncryptionPort(recoveryKey: "right"))
        for _ in 0..<500_000 where !model.needsRecovery { await Task.yield() }
        #expect(model.needsRecovery)

        model.key = "wrong"
        await model.submit()
        #expect(model.key.isEmpty)
        for _ in 0..<500_000 where model.errorMessage == nil { await Task.yield() }
        #expect(model.errorMessage?.contains("doesn't match") == true)

        model.key = "right"
        await model.submit()
        for _ in 0..<500_000 where !model.isVerified { await Task.yield() }
        #expect(model.isVerified && !model.needsRecovery && model.errorMessage == nil)
    }

    @Test("error messages never echo the key or server text")
    func messages() {
        #expect(!RecoveryViewModel.message(for: .invalidInput("RECOVERY_KEY")).contains("RECOVERY_KEY"))
        #expect(RecoveryViewModel.message(for: .network(retryable: true)).contains("connection"))
    }

    @Test("replaceRecovery resets the key and immediately recovers the creating device so it ends up verified")
    func replaceRecoveryVerifiesDevice() async throws {
        let port = FakeEncryptionPort(recoveryKey: "old-key", verified: false)
        let model = try await model(port)
        for _ in 0..<500_000 where !model.needsRecovery { await Task.yield() }
        #expect(model.needsRecovery && !model.isVerified)
        let result = await model.replaceRecovery()
        guard case .success(let newKey) = result else {
            Issue.record("expected replaceRecovery to succeed, got \(result)")
            return
        }
        #expect(newKey != "old-key" && !newKey.isEmpty)
        for _ in 0..<500_000 where !model.isVerified { await Task.yield() }
        #expect(model.isVerified && !model.needsRecovery && model.deviceStatus == "Verified" && model.recoveryStatus == "On")
    }

    @Test("interactive SAS emoji verification updates verificationPhase and marks the device verified")
    func sasEmojiVerification() async throws {
        let port = FakeEncryptionPort(recoveryKey: "k", verified: false)
        let model = try await model(port)
        for _ in 0..<500_000 where !model.needsRecovery { await Task.yield() }
        #expect(model.verificationPhase == .idle)

        await model.requestDeviceVerification()
        for _ in 0..<500_000 where model.verificationPhase != .waitingForOtherDevice { await Task.yield() }
        #expect(model.verificationPhase == .waitingForOtherDevice)

        let emojis = [VerificationEmoji(symbol: "🔑", description: "Key"), VerificationEmoji(symbol: "🛡", description: "Shield")]
        port.simulateVerificationPhase(.comparingEmojis(emojis))
        for _ in 0..<500_000 where model.verificationPhase != .comparingEmojis(emojis) { await Task.yield() }
        #expect(model.verificationPhase == .comparingEmojis(emojis))

        await model.approveVerification()
        for _ in 0..<500_000 where model.verificationPhase != .waitingForPartnerConfirmation { await Task.yield() }
        #expect(model.verificationPhase == .waitingForPartnerConfirmation)

        port.simulateVerificationPhase(.verified)
        for _ in 0..<500_000 where !model.isVerified { await Task.yield() }
        #expect(model.isVerified && !model.needsRecovery && model.verificationPhase == .verified)
    }
}
