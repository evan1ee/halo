import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// Halo's adapter and the SDK behind a broken network (ROADMAP M17-6): a throwaway Synapse behind infra/test's fault proxy. Run with
/// `infra/test/run.sh faults`; skipped otherwise. A `FAULT` line per test says how long recovery took.
@Suite("Faults", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh faults"))
struct FaultTests {
    @Test("The server goes away for five seconds: sync says so, comes back by itself and delivers what was missed", .timeLimit(.minutes(3)))
    func outage() async throws {
        let stage = try await TestStage()
        try await stage.proxy.fault(["action": "refuse"])
        try await stage.wait(60, "sync reports the outage") { [.offline, .failed].contains(stage.sync.last) }
        try await stage.peer.send("missed", to: stage.room)
        try await Task.sleep(for: .seconds(5))
        let back = ContinuousClock.now
        try await stage.proxy.heal()
        try await stage.wait(60, "the missed message") { stage.mirror.shows("missed") }
        stage.report("outage", since: back)
    }

    @Test("A half-open connection: the hung sync is given up and the message still arrives", .timeLimit(.minutes(4)))
    func halfOpenSync() async throws {
        let stage = try await TestStage()
        try await stage.proxy.fault(["action": "hang", "path": "/sync", "times": 1])
        try await stage.wait(30, "a sync request hangs") { try await stage.proxy.hits() == 1 }
        try await stage.peer.send("behind the hang", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(120, "the message") { stage.mirror.shows("behind the hang") }
        stage.report("halfOpenSync", since: start)
    }

    @Test("A sync response that breaks off is fetched again; nothing is lost", .timeLimit(.minutes(3)))
    func cutSync() async throws {
        let stage = try await TestStage()
        try await stage.proxy.fault(["action": "cut", "bytes": 40, "path": "/sync", "times": 1])
        // The poll already under way isn't affected: the message must go into the response that breaks off.
        try await stage.wait(30, "the next sync") { try await stage.proxy.hits() == 1 }
        try await stage.peer.send("cut off", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(60, "the message") { stage.mirror.shows("cut off") }
        stage.report("cutSync", since: start)
    }

    @Test("Server errors on sync are retried", .timeLimit(.minutes(3)))
    func syncServerErrors() async throws {
        let stage = try await TestStage()
        try await stage.proxy.fault(["action": "status", "status": 502, "path": "/sync", "times": 3])
        try await stage.wait(30, "the next sync") { try await stage.proxy.hits() >= 1 }
        try await stage.peer.send("after 502", to: stage.room)
        let start = ContinuousClock.now
        try await stage.wait(60, "the message") { stage.mirror.shows("after 502") }
        stage.report("syncServerErrors", since: start)
    }

    @Test("A send is delivered exactly once", .timeLimit(.minutes(3)), arguments: [
        Broken(name: "lost answer", rule: ["action": "lose", "path": "/send/", "times": 1]),
        Broken(name: "rate limited twice", rule: ["action": "status", "status": 429, "retry_after_ms": 600, "path": "/send/", "times": 2]),
        Broken(name: "server error twice", rule: ["action": "status", "status": 503, "path": "/send/", "times": 2]),
        Broken(name: "connection dropped", rule: ["action": "drop", "path": "/send/", "times": 1]),
        Broken(name: "slow network", rule: ["action": "delay", "ms": 4000, "path": "/send/", "times": 1]),
    ])
    func sendOnce(_ broken: Broken) async throws {
        let stage = try await TestStage()
        try await stage.proxy.fault(broken.rule)
        let start = ContinuousClock.now
        for number in 1...3 { try await stage.timeline.send(text: "m\(number)", mentions: []) }
        try await stage.wait(90, "all three sent (\(broken.name))") {
            (1...3).allSatisfy { stage.mirror.own("m\($0)")?.sendState == .sent }
        }
        stage.report("sendOnce, \(broken.name)", since: start)
        #expect(try await stage.proxy.hits() >= 1, "the fault was met")
        try await stage.proxy.heal()
        let bodies = try await ServerMessages(server: stage.direct, room: stage.room).bodies(user: stage.user, password: stage.password)
        #expect(Array(bodies.reversed()) == ["m1", "m2", "m3"], "\(broken.name)")
    }

    struct Broken: Sendable, CustomTestStringConvertible {
        let name: String
        let rule: [String: any Sendable]
        var testDescription: String { name }
    }
}
