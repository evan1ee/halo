import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("PushCoordinator")
struct PushCoordinatorTests {
    private func make(_ push: FakePushPort) async throws -> (PushCoordinator, SessionCoordinator, FakeSessionPort) {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        await session.start()
        let gateway = try #require(URL(string: "http://sygnal:5000/_matrix/push/v1/notify"))
        let coordinator = PushCoordinator(port: push, session: session, appID: "one.mbm.halo.dev", gatewayURL: gateway)
        await coordinator.begin()
        return (coordinator, session, sessionPort)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500_000 { if condition() { return true }; await Task.yield() }
        return false
    }

    private func signIn(_ session: SessionCoordinator) async {
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
    }

    @Test("a token received before sign-in is registered once the session is ready, and only once")
    func tokenThenSession() async throws {
        let push = FakePushPort()
        let (coordinator, session, _) = try await make(push)
        let token = Data([1, 2, 3])
        await coordinator.deviceTokenReceived(token)
        #expect(push.registrations.isEmpty)
        await signIn(session)
        #expect(await eventually { push.registrations.count == 1 })
        await coordinator.deviceTokenReceived(token)  // same token again: nothing new
        #expect(push.registrations == [.init(deviceToken: token, appID: "one.mbm.halo.dev", gatewayURL: try #require(URL(string: "http://sygnal:5000/_matrix/push/v1/notify")))])
    }

    @Test("a refreshed token registers again; a failed registration is retried")
    func refreshAndRetry() async throws {
        let push = FakePushPort()
        let (coordinator, session, _) = try await make(push)
        await signIn(session)
        await coordinator.deviceTokenReceived(Data([0]))
        #expect(await eventually { push.registrations.count == 1 })  // the session is ready now
        push.failNext()
        await coordinator.deviceTokenReceived(Data([1]))
        #expect(push.registrations.count == 1)  // the registration failed
        await coordinator.retry()
        #expect(push.registrations.map(\.deviceToken) == [Data([0]), Data([1])])
        await coordinator.deviceTokenReceived(Data([2]))
        #expect(push.registrations.map(\.deviceToken) == [Data([0]), Data([1]), Data([2])])
    }

    @Test("signing out removes the pusher first, while the session is still valid")
    func unregistersOnLogout() async throws {
        let push = FakePushPort()
        let (coordinator, session, _) = try await make(push)
        await session.setBeforeSignOut { await coordinator.unregister() }
        let token = Data([4, 5, 6])
        await coordinator.deviceTokenReceived(token)
        await signIn(session)
        #expect(await eventually { push.registrations.count == 1 })
        await session.logout()
        #expect(push.unregistrations == [token])
    }
}
