import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("SyncCoordinator")
struct SyncCoordinatorTests {
    private final class Sleeps: Sendable {
        let durations = Mutex<[Duration]>([])
        func record(_ duration: Duration) { durations.withLock { $0.append(duration) } }
    }

    /// A signed-in session and a coordinator over the fake port; sleeps are recorded, never waited.
    private func make() async throws -> (SyncCoordinator, FakeSyncPort, SessionCoordinator, Sleeps) {
        let sessionPort = FakeSessionPort()
        let url = try #require(URL(string: "https://example.org"))
        sessionPort.addServer("example.org", ServerDetails(homeserverURL: url, supportsPassword: true, supportsOIDC: false, supportsNativeSlidingSync: true))
        sessionPort.addAccount(.init(localpart: "alice", password: "pw"))
        let session = SessionCoordinator(port: sessionPort, keychain: InMemoryKeychain())
        await session.start()
        let port = FakeSyncPort()
        let sleeps = Sleeps()
        let coordinator = SyncCoordinator(port: port, session: session, sleep: { sleeps.record($0) })
        await coordinator.begin()
        return (coordinator, port, session, sleeps)
    }

    private func signIn(_ session: SessionCoordinator) async {
        await session.discover(server: "example.org")
        await session.loginPassword(username: "alice", password: "pw")
    }

    /// Yields until `condition` holds (bounded, no sleeping); robust against states that pass quickly.
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func until(_ coordinator: SyncCoordinator, _ status: SyncStatus) async {
        for await value in await coordinator.statuses() where value == status { return }
    }

    @Test("sync runs only while signed in and in the foreground")
    func foregroundAndSession() async throws {
        let (coordinator, port, session, _) = try await make()
        await coordinator.setForeground(true)
        #expect(port.startCalls == 0)  // no session yet
        await signIn(session)
        await until(coordinator, .running)
        #expect(port.startCalls == 1)
        await coordinator.setForeground(false)
        #expect(port.stopCalls == 1)
        await coordinator.setForeground(true)
        await until(coordinator, .running)
        #expect(port.startCalls == 2)
    }

    @Test("signing out stops the loop")
    func logoutStops() async throws {
        let (coordinator, port, session, _) = try await make()
        await signIn(session)
        await coordinator.setForeground(true)
        await until(coordinator, .running)
        await session.logout()
        await until(coordinator, .stopped)
        #expect(port.stopCalls >= 1)
    }

    @Test("a failed loop restarts with doubling delays and the counter resets once it runs again")
    func backoff() async throws {
        let (coordinator, port, session, sleeps) = try await make()
        await signIn(session)
        await coordinator.setForeground(true)
        await until(coordinator, .running)
        port.report(.failed)
        #expect(await eventually { sleeps.durations.withLock { $0 }.count == 1 && port.status == .running })  // restarted
        #expect(sleeps.durations.withLock { $0 } == [.seconds(1)])
        port.report(.failed)
        #expect(await eventually { sleeps.durations.withLock { $0 }.count == 2 && port.status == .running })
        #expect(sleeps.durations.withLock { $0 } == [.seconds(1), .seconds(1)])  // counter reset after running
    }

    @Test("the backoff doubles up to 60 s")
    func backoffSchedule() {
        let delays = (1...9).map { SyncCoordinator.backoff(afterFailures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60].map { Duration.seconds($0) })
    }

    @Test("a retryable start error is retried, a non-retryable one is not")
    func startErrors() async throws {
        let (coordinator, port, session, sleeps) = try await make()
        await signIn(session)
        port.failNextStart(with: .network(retryable: true))
        await coordinator.setForeground(true)
        await until(coordinator, .running)
        #expect(sleeps.durations.withLock { $0 }.count == 1)

        await coordinator.setForeground(false)
        port.failNextStart(with: .unauthorized(soft: false))
        let before = sleeps.durations.withLock { $0 }.count
        await coordinator.setForeground(true)
        #expect(sleeps.durations.withLock { $0 }.count == before)
    }

    @Test("syncOnceInBackground runs one bounded sync pass while backgrounded without starting the foreground loop")
    func backgroundSyncOnce() async throws {
        let (coordinator, port, session, _) = try await make()
        #expect(await coordinator.syncOnceInBackground() == false)
        #expect(port.syncOnceCalls == 0)

        await signIn(session)
        #expect(await eventually { await coordinator.syncOnceInBackground() })
        #expect(port.syncOnceCalls >= 1)
        #expect(port.startCalls == 0)
    }
}
