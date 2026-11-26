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

    struct Broken: Sendable, CustomTestStringConvertible {
        let name: String
        let rule: [String: any Sendable]
        var testDescription: String { name }
    }
}
