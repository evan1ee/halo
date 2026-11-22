import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("SessionCoordinator", .timeLimit(.minutes(1)))
struct SessionCoordinatorTests {
    private func signedIn() async throws -> (SessionCoordinator, FakeSessionPort, InMemoryKeychain) {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        await coordinator.loginPassword(username: "alice", password: "correct horse")
        #expect(await coordinator.state == .ready(try UserID("@alice:halo.localhost")))
        return (coordinator, port, keychain)
    }

    @Test("first launch without a stored session is signed out")
    func firstLaunch() async {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        #expect(await coordinator.state == .signedOut(failure: nil))
        #expect(port.calls.isEmpty)
    }

    @Test("password login persists the session and becomes ready (AC-AUTH-1)")
    func login() async throws {
        let (_, _, keychain) = try await signedIn()
        let stored = try #require(keychain.stored(.session))
        let session = try JSONDecoder().decode(StoredSession.self, from: stored)
        #expect(session.userID == (try UserID("@alice:halo.localhost")))
    }

    @Test("a relaunch restores the stored session without logging in again (AC-AUTH-2)")
    func relaunch() async throws {
        let (_, port, keychain) = try await signedIn()
        let relaunched = SessionCoordinator(port: port, keychain: keychain)
        await relaunched.start()
        #expect(await relaunched.state == .ready(try UserID("@alice:halo.localhost")))
        #expect(port.calls.filter { $0 == "loginPassword" }.count == 1)
        #expect(port.calls.last == "restore")
    }

    @Test("a wrong password stays on the method screen with the error")
    func wrongPassword() async {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        await coordinator.loginPassword(username: "alice", password: "wrong")
        #expect(await coordinator.state == .choosingMethod(devServer, failure: .unauthorized(soft: false)))
        #expect(keychain.stored(.session) == nil)
    }

    @Test("R-17 (D81): servers without native sliding sync are accepted because Halo uses classic sync (D74)")
    func classicSyncServerAccepted() async {
        let (port, keychain) = makeSessionFixture()
        let classicServer = ServerDetails(homeserverURL: URL(string: "https://old.example")!,
                                          supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: false)
        port.addServer("old.example", classicServer)
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "  old.example \n")
        #expect(await coordinator.state == .choosingMethod(classicServer, failure: nil))
    }

    @Test("discovery errors and empty input are reported")
    func discoveryErrors() async {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "   ")
        #expect(await coordinator.state == .signedOut(failure: .invalidInput("SERVER_EMPTY")))
        await coordinator.discover(server: "unknown.example")
        #expect(await coordinator.state == .signedOut(failure: .notFound))
    }

    @Test("a homeserver that never answers ends discovery with a retryable network error instead of spinning forever")
    func discoveryTimesOut() async {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain, discoveryTimeout: .milliseconds(100))
        await coordinator.start()
        port.delayLoginDetails(by: .seconds(30))
        await coordinator.discover(server: "halo.localhost")
        #expect(await coordinator.state == .signedOut(failure: .network(retryable: true)))
        // The next attempt works once the host answers.
        port.delayLoginDetails(by: .zero)
        await coordinator.discover(server: "halo.localhost")
        if case .choosingMethod = await coordinator.state {} else { Issue.record("expected the method screen") }
    }

    @Test("a second login while authenticating is ignored")
    func doubleTap() async throws {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        async let first: Void = coordinator.loginPassword(username: "alice", password: "correct horse")
        async let second: Void = coordinator.loginPassword(username: "alice", password: "correct horse")
        _ = await (first, second)
        #expect(port.calls.filter { $0 == "loginPassword" }.count == 1)
        #expect(await coordinator.state == .ready(try UserID("@alice:halo.localhost")))
    }

    @Test("if the session can't be persisted, the new device is signed out again")
    func persistFailure() async {
        let (port, keychain) = makeSessionFixture()
        keychain.failWrites = true
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        await coordinator.loginPassword(username: "alice", password: "correct horse")
        #expect(await coordinator.state == .choosingMethod(devServer, failure: .storage(.unavailable)))
        #expect(port.calls.last == "logout")
    }

    @Test("a locked Keychain at launch keeps the session for a retry")
    func lockedKeychain() async throws {
        let (_, port, keychain) = try await signedIn()
        keychain.isUnavailable = true
        let relaunched = SessionCoordinator(port: port, keychain: keychain)
        await relaunched.start()
        #expect(await relaunched.state == .restoreFailed(.storage(.unavailable)))
        keychain.isUnavailable = false
        await relaunched.retryRestore()
        #expect(await relaunched.state == .ready(try UserID("@alice:halo.localhost")))
    }

    @Test("a corrupted stored session signs out")
    func corruptedSession() async {
        let (port, keychain) = makeSessionFixture()
        keychain.store(Data("not json".utf8), for: .session)
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        #expect(await coordinator.state == .signedOut(failure: .storage(.corrupted)))
    }

    @Test("a soft-revoked token restores into soft logout and keeps the session (FR-9)")
    func softRevoked() async throws {
        let (_, port, keychain) = try await signedIn()
        let session = try JSONDecoder().decode(StoredSession.self, from: try #require(keychain.stored(.session)))
        port.revoke(session, soft: true)
        let relaunched = SessionCoordinator(port: port, keychain: keychain)
        await relaunched.start()
        #expect(await relaunched.state == .softLoggedOut(try UserID("@alice:halo.localhost")))
        #expect(keychain.stored(.session) != nil)
    }

    @Test("a hard-revoked token forgets the session")
    func hardRevoked() async throws {
        let (_, port, keychain) = try await signedIn()
        let session = try JSONDecoder().decode(StoredSession.self, from: try #require(keychain.stored(.session)))
        port.revoke(session, soft: false)
        let relaunched = SessionCoordinator(port: port, keychain: keychain)
        await relaunched.start()
        #expect(await relaunched.state == .signedOut(failure: .unauthorized(soft: false)))
        #expect(keychain.stored(.session) == nil)
    }

    @Test("a transient restore error keeps the session")
    func transientRestoreError() async throws {
        let (_, port, keychain) = try await signedIn()
        port.failNext("restore", with: .network(retryable: true))
        let relaunched = SessionCoordinator(port: port, keychain: keychain)
        await relaunched.start()
        #expect(await relaunched.state == .restoreFailed(.network(retryable: true)))
        #expect(keychain.stored(.session) != nil)
    }

    @Test("a homeserver that never answers ends the restore with a retryable error instead of loading forever, and keeps the session")
    func restoreTimesOut() async throws {
        let (_, port, keychain) = try await signedIn()
        port.delayRestore(by: .seconds(30))
        let relaunched = SessionCoordinator(port: port, keychain: keychain, restoreTimeout: .milliseconds(100))
        await relaunched.start()
        #expect(await relaunched.state == .restoreFailed(.network(retryable: true)))
        #expect(keychain.stored(.session) != nil)
    }

    @Test("refreshed tokens are persisted at once (FR-7)")
    func tokenRefresh() async throws {
        let (coordinator, port, keychain) = try await signedIn()
        let refreshed = StoredSession(userID: try UserID("@alice:halo.localhost"), deviceID: try DeviceID("FAKEDEVICE7"), payload: Data("refreshed".utf8))
        let states = await coordinator.states()
        port.send(.tokensRefreshed(refreshed))
        port.send(.softLoggedOut) // a later event proves the refresh was handled first (one ordered stream)
        _ = await first(states) { if case .softLoggedOut = $0 { true } else { false } }
        #expect(try JSONDecoder().decode(StoredSession.self, from: try #require(keychain.stored(.session))) == refreshed)
        #expect(await coordinator.lastBackgroundFailure == nil)
    }

    @Test("an SDK logout forgets the session")
    func sdkLogout() async throws {
        let (coordinator, port, keychain) = try await signedIn()
        let states = await coordinator.states()
        port.send(.loggedOut)
        let state = await first(states) { if case .signedOut = $0 { true } else { false } }
        #expect(state == .signedOut(failure: .unauthorized(soft: false)))
        #expect(keychain.stored(.session) == nil)
    }

    @Test("logout removes the stored session even if the server is unreachable (FR-8)")
    func logoutOffline() async throws {
        let (coordinator, port, keychain) = try await signedIn()
        port.failNext("logout", with: .network(retryable: true))
        await coordinator.logout()
        #expect(await coordinator.state == .signedOut(failure: .network(retryable: true)))
        #expect(keychain.stored(.session) == nil)
    }

    @Test("state subscribers get the current state at once and always the newest state")
    func stateStream() async throws {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        var iterator = await coordinator.states().makeAsyncIterator()
        #expect(await iterator.next() == .launching)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        // Intermediate states may be skipped (latest wins); the newest one is never lost.
        var latest: SessionCoordinator.State?
        while let state = await iterator.next() {
            latest = state
            if case .choosingMethod = state { break }
        }
        #expect(latest == .choosingMethod(devServer, failure: nil))
    }

    @Test("changeServer returns from choosingMethod to signedOut and does nothing in other states")
    func changeServer() async throws {
        let (port, keychain) = makeSessionFixture()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "halo.localhost")
        #expect(await coordinator.state == .choosingMethod(devServer, failure: nil))
        await coordinator.changeServer()
        #expect(await coordinator.state == .signedOut(failure: nil))
        // No-op when signed in.
        let (signedInCoordinator, _, _) = try await signedIn()
        await signedInCoordinator.changeServer()
        if case .ready = await signedInCoordinator.state {} else { Issue.record("expected .ready") }
    }

    @Test("PS34 (R-10): remote logout during sync moves session out of ready and stops sync without restarting")
    func remoteLogoutStopsSync() async throws {
        let (coordinator, port, keychain) = try await signedIn()
        let syncPort = FakeSyncPort()
        let sync = SyncCoordinator(port: syncPort, session: coordinator, sleep: { _ in })
        await sync.begin()
        await sync.setForeground(true)
        for _ in 0..<50_000 where syncPort.startCalls == 0 { await Task.yield() }
        #expect(syncPort.startCalls == 1)

        // Remote soft logout arrives via ClientDelegate / sessionUpdates.
        port.send(.softLoggedOut)
        for _ in 0..<50_000 where syncPort.stopCalls == 0 { await Task.yield() }
        #expect(await coordinator.state == .softLoggedOut(try UserID("@alice:halo.localhost")))
        #expect(syncPort.stopCalls == 1)
        #expect(keychain.stored(.session) != nil)

        // Remote hard logout forgets the session and keeps sync stopped.
        let (c2, p2, k2) = try await signedIn()
        let sp2 = FakeSyncPort()
        let s2 = SyncCoordinator(port: sp2, session: c2, sleep: { _ in })
        await s2.begin()
        await s2.setForeground(true)
        for _ in 0..<50_000 where sp2.startCalls == 0 { await Task.yield() }
        p2.send(.loggedOut)
        for _ in 0..<50_000 where sp2.stopCalls == 0 { await Task.yield() }
        #expect(await c2.state == .signedOut(failure: .unauthorized(soft: false)))
        #expect(k2.stored(.session) == nil)
        #expect(sp2.startCalls == 1 && sp2.stopCalls == 1)
    }

    @Test("PS35 (R-12): restore timeout keeps restore single-flight; retry awaits the same call and late completion after logout is discarded")
    func singleFlightRestore() async throws {
        // (a) Timeout followed by retry while still in flight: port.restore called once, ends ready.
        let (_, port, keychain) = try await signedIn()
        port.holdRestore()
        let relaunched = SessionCoordinator(port: port, keychain: keychain, restoreTimeout: .milliseconds(50))
        await relaunched.start()
        #expect(await relaunched.state == .restoreFailed(.network(retryable: true)))
        let restoreCountBeforeRetry = port.calls.filter { $0 == "restore" }.count
        #expect(restoreCountBeforeRetry == 1)

        let retry = Task { await relaunched.retryRestore() }
        try await Task.sleep(for: .milliseconds(20))
        port.releaseRestore()
        await retry.value
        #expect(port.calls.filter { $0 == "restore" }.count == 1)
        #expect(await relaunched.state == .ready(try UserID("@alice:halo.localhost")))

        // (b) Timeout followed by late completion while still on restoreFailed: adopts cleanly into ready.
        let (_, port2, keychain2) = try await signedIn()
        port2.holdRestore()
        let relaunched2 = SessionCoordinator(port: port2, keychain: keychain2, restoreTimeout: .milliseconds(50))
        await relaunched2.start()
        #expect(await relaunched2.state == .restoreFailed(.network(retryable: true)))
        port2.releaseRestore()
        for _ in 0..<50_000 {
            if case .ready = await relaunched2.state { break }
            await Task.yield()
        }
        #expect(await relaunched2.state == .ready(try UserID("@alice:halo.localhost")))

        // (c) Timeout followed by user sign-out before late completion: stays signed out.
        let (_, port3, keychain3) = try await signedIn()
        port3.holdRestore()
        let relaunched3 = SessionCoordinator(port: port3, keychain: keychain3, restoreTimeout: .milliseconds(50))
        await relaunched3.start()
        #expect(await relaunched3.state == .restoreFailed(.network(retryable: true)))
        await relaunched3.logout()
        #expect(await relaunched3.state == .signedOut(failure: nil))
        port3.releaseRestore()
        for _ in 0..<5_000 { await Task.yield() }
        #expect(await relaunched3.state == .signedOut(failure: nil))
    }

    @Test("OIDC login persists the session and reaches ready; cancel aborts and returns to choosingMethod")
    func oidcFlow() async throws {
        let port = FakeSessionPort()
        let oidcServer = ServerDetails(
            homeserverURL: try #require(URL(string: "https://oidc.halo.localhost")),
            supportsPassword: false, supportsOIDC: true, supportsNativeSlidingSync: true)
        port.addServer("oidc.halo.localhost", oidcServer)
        port.addAccount(.init(localpart: "alice", password: "unused"))
        let keychain = InMemoryKeychain()
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "oidc.halo.localhost")
        #expect(await coordinator.state == .choosingMethod(oidcServer, failure: nil))

        let cancelURL = await coordinator.beginOAuth()
        #expect(cancelURL?.absoluteString.contains("oauth/authorize") == true)
        #expect(await coordinator.state == .authenticating(oidcServer))
        await coordinator.cancelOAuth()
        #expect(await coordinator.state == .choosingMethod(oidcServer, failure: nil))
        #expect(port.calls.contains("abortOAuth"))

        let authURL = await coordinator.beginOAuth()
        #expect(authURL != nil)
        await coordinator.completeOAuth(callbackURL: try #require(URL(string: "one.mbm.halo:/oauth/callback?code=xyz")))
        #expect(await coordinator.state == .ready(try UserID("@alice:oidc.halo.localhost")))
        #expect(keychain.stored(.session) != nil)
    }
}
