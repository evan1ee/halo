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

    @Test("servers without native sliding sync are rejected (FR-5)")
    func noSlidingSync() async {
        let (port, keychain) = makeSessionFixture()
        port.addServer("old.example", ServerDetails(homeserverURL: URL(string: "https://old.example")!,
                                                     supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: false))
        let coordinator = SessionCoordinator(port: port, keychain: keychain)
        await coordinator.start()
        await coordinator.discover(server: "  old.example \n")
        #expect(await coordinator.state == .signedOut(failure: .unsupported("NO_SLIDING_SYNC")))
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
}
