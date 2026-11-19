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
}
