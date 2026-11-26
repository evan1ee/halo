import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// Halo's adapter and the SDK behind a broken network (ROADMAP M17-6): a throwaway Synapse behind infra/test's fault proxy. Run with
/// `infra/test/run.sh faults`; skipped otherwise. A `FAULT` line per test says how long recovery took.
private let env = ProcessInfo.processInfo.environment

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

    @Test("Every kind of own message reaches the server exactly once, whatever breaks (M18-11, AC-REL-3)", .timeLimit(.minutes(5)), arguments: [
        Broken(name: "lost answer", rule: ["action": "lose", "path": "/send/|/upload", "times": 4]),
        Broken(name: "rate limited", rule: ["action": "status", "status": 429, "retry_after_ms": 600, "path": "/send/|/upload", "times": 4]),
        Broken(name: "connection dropped", rule: ["action": "drop", "path": "/send/|/upload", "times": 4]),
    ])
    func everyKindOnce(_ broken: Broken) async throws {
        let stage = try await TestStage()
        try await stage.timeline.send(text: "base", mentions: [])
        try await stage.wait(60, "the base message") { stage.mirror.own("base")?.sendState == .sent }
        let base = try #require(stage.mirror.own("base")?.eventID)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let mxc = try await stage.peer.upload(png, type: "image/png")
        let sticker = Sticker(pack: PackRef(room: stage.room, stateKey: "p"), shortcode: "dot", body: "dot", url: mxc, info: nil)

        try await stage.proxy.fault(broken.rule)
        let start = ContinuousClock.now
        var refused: [String] = []
        func attempt(_ kind: String, _ send: () async throws -> Void) async { do { try await send() } catch { refused.append("\(kind): \(error)") } }
        await attempt("reply") { try await stage.timeline.reply(to: base, text: "the reply", mentions: []) }
        await attempt("edit") { try await stage.timeline.edit(event: base, newText: "base, edited") }
        await attempt("reaction") { try await stage.timeline.toggleReaction(on: base, key: "👍") }
        await attempt("image") { try await stage.timeline.sendImage(OutgoingImage(data: png, filename: "dot.png", mimeType: "image/png", width: 1, height: 1)) }
        await attempt("file") { try await stage.timeline.sendFile(OutgoingFile(data: Data("file".utf8), filename: "note.txt", mimeType: "text/plain")) }
        await attempt("sticker") { try await stage.timeline.sendSticker(sticker) }
        print("FAULT everyKindOnce, \(broken.name): refused \(refused)")

        func counts() async throws -> [String: Int] {
            var found: [String: Int] = [:]
            for event in try await stage.peer.events(in: stage.room) {
                let content = event["content"] as? [String: Any] ?? [:]
                let relation = content["m.relates_to"] as? [String: Any]
                let kind: String?
                switch event["type"] as? String {
                case "m.sticker": kind = "sticker"
                case "m.reaction": kind = "reaction"
                case "m.room.message":
                    if relation?["rel_type"] as? String == "m.replace" { kind = "edit" }
                    else if content["body"] as? String == "the reply" { kind = "reply" }
                    else if content["msgtype"] as? String == "m.image" { kind = "image" }
                    else if content["msgtype"] as? String == "m.file" { kind = "file" }
                    else if content["body"] as? String == "base" { kind = "base" }
                    else { kind = nil }
                default: kind = nil
                }
                if let kind { found[kind, default: 0] += 1 }
            }
            return found
        }
        // A sticker is sent at once, outside the send queue (the SDK offers no queued sticker), so it is not retried: a refusal is
        // shown to the person, who sends it again. Everything else goes through the queue and must arrive exactly once.
        let queued = ["base", "reply", "edit", "reaction", "image", "file"]
        #expect(refused.allSatisfy { $0.hasPrefix("sticker") }, "only a sticker may be refused: \(refused)")
        try await stage.wait(120, "all queued kinds on the server (\(broken.name))") { try await counts().count >= queued.count }
        stage.report("everyKindOnce, \(broken.name)", since: start)
        try await stage.proxy.heal()
        try await Task.sleep(for: .seconds(8))  // a late duplicate would show up now
        let final = try await counts()
        for kind in queued { #expect(final[kind] == 1, "\(kind) arrived \(final[kind] ?? 0) times (\(broken.name))") }
        #expect(final["sticker"] == (refused.isEmpty ? 1 : nil) || (final["sticker"] ?? 0) <= 1, "a sticker is never sent twice by itself")
        try await stage.wait(30, "no send is left pending") {
            stage.mirror.own("base") == nil || stage.mirror.own("base")?.sendState == .sent
        }
    }

    @Test("The app is killed with messages waiting to go out: after the restart they arrive once and in order (M18-11)", .timeLimit(.minutes(5)), arguments: [
        Broken(name: "server errors", rule: ["action": "status", "status": 503, "path": "/send/", "times": 50]),
        Broken(name: "answers lost", rule: ["action": "lose", "path": "/send/", "times": 50]),
    ])
    func killedMidSend(_ broken: Broken) async throws {
        let proxy = ProxyControl()
        try await proxy.heal()
        let user = env["HALO_FAULT_USER"] ?? "", password = env["HALO_FAULT_PASSWORD"] ?? "", direct = env["HALO_FAULT_DIRECT"] ?? ""
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-kill-\(UUID().uuidString)")
        let peer = try await TestPeer(server: direct, user: user + "peer", password: password)
        Cleanup.current.add { await peer.logout() }
        Cleanup.current.add { try? await proxy.heal() }
        let room = try await peer.makeRoom()
        let joined = try await TestPeer(server: direct, user: user, password: password)
        try await joined.join(room)
        await joined.logout()

        // First run of the app: three messages are written while the server refuses or loses every send, then the process "dies".
        let stored: StoredSession
        do {
            let session = MatrixSessionPort(baseDirectory: directory)
            let details = try await session.loginDetails(server: env["HALO_FAULT_SERVER"] ?? "")
            stored = try await session.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "kill"), on: details)
            let sync = SyncFollower(MatrixSyncPort(session: session))
            try await sync.start()
            var opened: (any TimelineSession)?
            for _ in 0..<60 where opened == nil {
                opened = try? await MatrixTimelinePort(session: session).open(room: room)
                if opened == nil { try await Task.sleep(for: .milliseconds(500)) }
            }
            let timeline = try #require(opened)
            let mirror = TimelineMirror(timeline.items())
            try await proxy.fault(broken.rule)
            for number in 1...3 { try await timeline.send(text: "k\(number)", mentions: []) }
            try await mirror.wait(seconds: 30, "the three local echoes") { mirror in (1...3).allSatisfy { mirror.own("k\($0)") != nil } ? true : nil }
            await sync.stop()
            await timeline.close()
        }
        try await Task.sleep(for: .seconds(2))
        if broken.rule["action"] as? String == "status" {
            let sent = try await peer.events(in: room).filter { $0["type"] as? String == "m.room.message" }
            #expect(sent.isEmpty, "with the server refusing, nothing went out before the kill")
        }

        // Second run: the stored session comes back, the network is healthy, nothing is typed again.
        try await proxy.heal()
        let session = MatrixSessionPort(baseDirectory: directory)
        Cleanup.current.add { try? await session.logout() }
        try await session.restore(stored)
        let sync = SyncFollower(MatrixSyncPort(session: session))
        Cleanup.current.add { await sync.stop() }
        try await sync.start()
        let start = ContinuousClock.now
        func bodies() async throws -> [String] {
            try await peer.events(in: room).compactMap { event in
                guard event["type"] as? String == "m.room.message" else { return nil }
                return (event["content"] as? [String: Any])?["body"] as? String
            }
        }
        var seen: [String] = []
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            seen = try await bodies()
            if seen.count >= 3 { break }
            try await Task.sleep(for: .seconds(1))
        }
        print("FAULT killedMidSend, \(broken.name): \(seen) after \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
        try await Task.sleep(for: .seconds(8))  // a late duplicate would show up now
        #expect(try await bodies() == ["k1", "k2", "k3"], "\(broken.name)")
    }

    @Test("The access token stops working while a message is sent: the message is kept, says it wasn't sent, and goes out once after signing in again (M18-11)", .timeLimit(.minutes(5)))
    func tokenExpiresMidSend() async throws {
        let stage = try await TestStage()
        let expired: [String: any Sendable] = ["errcode": "M_UNKNOWN_TOKEN", "error": "Access token has expired", "soft_logout": true]
        try await stage.proxy.fault(["action": "status", "status": 401, "body": expired, "path": "/send/", "times": 50])
        try await stage.timeline.send(text: "after expiry", mentions: [])
        try await stage.wait(60, "the message is shown as not sent") {
            guard let own = stage.mirror.own("after expiry") else { return false }
            print("FAULT tokenExpiresMidSend: state \(own.sendState), failure \(String(describing: own.sendFailure))")
            return own.sendState != .sent && own.sendState != .sending
        }
        let before = try await stage.peer.events(in: stage.room).filter { $0["type"] as? String == "m.room.message" }
        #expect(before.isEmpty, "nothing reached the server while the token was refused")
        // Signing in again (the token works) and sending what is waiting: the person taps Retry.
        try await stage.proxy.heal()
        let own = try #require(stage.mirror.own("after expiry"))
        if let id = own.localID { try await stage.timeline.retrySend(localID: id) }
        try await stage.wait(60, "the message after signing in again") { stage.mirror.own("after expiry")?.sendState == .sent }
        try await Task.sleep(for: .seconds(5))
        let bodies = try await stage.peer.events(in: stage.room).compactMap { ($0["content"] as? [String: Any])?["body"] as? String }
        #expect(bodies == ["after expiry"], "exactly once")
    }

    struct Broken: Sendable, CustomTestStringConvertible {
        let name: String
        let rule: [String: any Sendable]
        var testDescription: String { name }
    }
}
