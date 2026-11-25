import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// Can the history of an encrypted room from before this device signed in be read for search (ROADMAP M17-8, V-SEARCH-3)? A throwaway Synapse;
/// run with `infra/test/run.sh search`. Prints `SPIKE` lines with counts.
@Suite("Search spike, encrypted history", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh search"))
struct SearchSpikeEncryptionTests {
    static let count = 400, perKey = 10

    @Test("A new device reads nothing before recovery and everything after it, paging an event-focused timeline", .timeLimit(.minutes(15)))
    func historyAfterRecovery() async throws {
        let server = env["HALO_FAULT_SERVER"] ?? "", user = env["HALO_FAULT_USER"] ?? "", password = env["HALO_FAULT_PASSWORD"] ?? ""
        try await ProxyControl().heal()

        // The old device: an encrypted room whose key changes every ten messages, and recovery with key backup.
        let old = MatrixSessionPort(baseDirectory: temporary())
        Cleanup.current.add { try? await old.logout() }
        let details = try await old.loginDetails(server: server)
        _ = try await old.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "old"), on: details)
        try await old.startSync()
        let roomID = try await makeRoom(old)
        let room = try await wait(30, "the room") { try? await old.room(roomID) }
        #expect(await room.isEncrypted())
        let timeline = try await room.timeline()
        for number in 0..<Self.count {
            _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: "encrypted \(number)"))
        }
        let sent = try await SearchSpikeReader(session: old)
        _ = try await wait(180, "every message to be sent") {
            let slice = try await sent.recent(roomID, maxPages: 20)
            return Set(slice.messages.filter { $0.eventID != nil }.compactMap(\.spikeText)).count == Self.count ? true : nil
        }
        let key = try await MatrixEncryptionPort(session: old).enableRecovery()
        try await old.encryption().waitForBackupUploadSteadyState(progressListener: nil)

        // The new device, before recovery.
        let directory = temporary()
        let new = MatrixSessionPort(baseDirectory: directory)
        Cleanup.current.add { try? await new.logout() }
        let stored = try await new.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "new"), on: details)
        try await new.startSync()
        _ = try await wait(30, "the room on the new device") { try? await new.room(roomID) }
        let reader = try await SearchSpikeReader(session: new)
        let newest = try await reader.recent(roomID, maxPages: 1)
        let anchor = try #require(newest.events.last { $0.eventID != nil }?.eventID)
        let caches = directory.appendingPathComponent("search-caches")
        func history() async throws -> SearchSpikeReader {
            try SearchSpikeReader(client: try await SearchSpikeHistoryClient.make(stored, directory: directory, caches: caches, room: roomID))
        }
        let before = try await history().history(roomID, before: anchor, pages: 20)
        print("SPIKE before recovery: \(before.undecryptable.count) undecryptable, \(before.messages.count) readable, start \(before.reachedStart)")
        #expect(before.reachedStart)
        #expect(before.undecryptable.count >= Self.count - 1)

        // Recovery, then the same pages again: keys come from the backup one by one after each failed decryption.
        try await MatrixEncryptionPort(session: new).recover(recoveryKey: key)
        try await new.encryption().waitForE2eeInitializationTasks()
        await ScaleStageProxy.reset()
        var start = ContinuousClock.now
        let own = try await history().history(roomID, before: anchor, pages: 20, waitForKeys: 60)
        print("SPIKE own client after recovery: \(own.messages.count) readable, \(own.undecryptable.count) undecryptable, \((ContinuousClock.now - start).formatted()), key requests \(await ScaleStageProxy.requests("room_keys")), all \(await ScaleStageProxy.requests(""))")
        await ScaleStageProxy.reset()
        start = .now
        let again = try await history().history(roomID, before: anchor, pages: 20, waitForKeys: 60)
        print("SPIKE own client, second pass: \(again.messages.count) readable, \(again.undecryptable.count) undecryptable, \((ContinuousClock.now - start).formatted()), key requests \(await ScaleStageProxy.requests("room_keys"))")
        await ScaleStageProxy.reset()
        start = .now
        let app = try await reader.history(roomID, before: anchor, pages: 20, waitForKeys: 60)
        print("SPIKE app client: \(app.messages.count) readable, \(app.undecryptable.count) undecryptable, \((ContinuousClock.now - start).formatted()), key requests \(await ScaleStageProxy.requests("room_keys"))")

        // The app itself still works on the shared store: it decrypts what it had shown as undecryptable, and sends.
        let shownAtOnce = try await reader.recent(roomID, maxPages: 20)
        let shown = try await reader.recent(roomID, maxPages: 20, waitForKeys: 60)
        print("SPIKE app timeline: at once \(shownAtOnce.undecryptable.count) undecryptable, after waiting \(shown.messages.count) readable, \(shown.undecryptable.count) undecryptable")
        // The live lane on listeners: a message of the old device arrives decrypted.
        let seen = SearchSpikeSeen()
        let handles = SearchSpikeListener.subscribe(try await new.room(roomID), seen: seen)
        defer { for handle in handles { handle.cancel() } }
        _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: "live and encrypted"))
        _ = try await wait(30, "the live message on the listener") { seen.value.withLock { $0.messages.isEmpty ? nil : true } }
        // A device the sender doesn't share keys with in time: what can't be decrypted arrives as encrypted, with its event ID.
        let blind = MatrixSessionPort(baseDirectory: temporary())
        Cleanup.current.add { try? await blind.logout() }
        let blindUser = user + "peer"
        _ = try await blind.loginPassword(PasswordCredentials(username: blindUser, password: password, deviceDisplayName: "blind"), on: details)
        try await invite(blindUser, to: roomID, by: old)
        try await blind.startSync()
        let invited = try await wait(30, "the invitation") { try? await blind.room(roomID) }
        try await invited.join()
        let unread = SearchSpikeSeen()
        let blindHandles = SearchSpikeListener.subscribe(try await blind.room(roomID), seen: unread)
        defer { for handle in blindHandles { handle.cancel() } }
        try await sendOpaque(to: roomID, by: old)
        _ = try await wait(30, "the undecryptable event on the listener") { unread.value.withLock { $0.encrypted.isEmpty ? nil : true } }
        print("SPIKE listener: live encrypted message readable, undecryptable event reported by ID")

        let newTimeline = try await (try await new.room(roomID)).timeline()
        _ = try await newTimeline.send(msg: messageEventContentFromMarkdown(md: "from the new device"))
        _ = try await wait(60, "the new device's message on the old one") {
            let slice = try await sent.recent(roomID)
            return slice.messages.contains { $0.spikeText == "from the new device" } ? true : nil
        }
        // The newest message can be the anchor's own; every other one must be readable.
        let readable = Set((own.messages.isEmpty ? again : own).messages.compactMap(\.spikeText) + again.messages.compactMap(\.spikeText))
        #expect(readable.count >= Self.count)
        #expect(again.undecryptable.isEmpty)
        #expect(shown.undecryptable.isEmpty)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("halo-spike-e2ee-\(UUID().uuidString)") }

    private func wait<T>(_ seconds: Double, _ what: String, _ value: () async throws -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            if let found = try await value() { return found }
            guard ContinuousClock.now < deadline else { throw ContractViolation("\(what): not within \(seconds) s") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func invite(_ user: String, to room: RoomID, by session: MatrixSessionPort) async throws {
        let sdk = try await session.signedInClient().session()
        let server = sdk.userId.split(separator: ":", maxSplits: 1)[1]
        try await call("POST", "rooms/\(room.rawValue)/invite", ["user_id": "@\(user):\(server)"], sdk)
    }

    /// An `m.room.encrypted` event nobody has a key for.
    private func sendOpaque(to room: RoomID, by session: MatrixSessionPort) async throws {
        let sdk = try await session.signedInClient().session()
        try await call("PUT", "rooms/\(room.rawValue)/send/m.room.encrypted/\(UUID().uuidString)", [
            "algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AwgAEnACgAkLmt6qF84IK", "session_id": "unknown", "sender_key": "x", "device_id": "y"], sdk)
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any], _ sdk: Session) async throws {
        let base = sdk.homeserverUrl.hasSuffix("/") ? sdk.homeserverUrl : sdk.homeserverUrl + "/"
        guard let url = URL(string: base + "_matrix/client/v3/" + path) else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + sdk.accessToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContractViolation("\(method) \(String(decoding: data.prefix(100), as: UTF8.self))") }
    }

    private func makeRoom(_ session: MatrixSessionPort) async throws -> RoomID {
        let sdk = try await session.signedInClient().session()
        let base = sdk.homeserverUrl.hasSuffix("/") ? sdk.homeserverUrl : sdk.homeserverUrl + "/"
        guard let url = URL(string: base + "_matrix/client/v3/createRoom") else { throw ContractViolation("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + sdk.accessToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "preset": "private_chat",
            "initial_state": [["type": "m.room.encryption", "state_key": "", "content": ["algorithm": "m.megolm.v1.aes-sha2", "rotation_period_msgs": Self.perKey]]],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try RoomID((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["room_id"] as? String ?? "")
    }
}

extension HaloDomain.TimelineEvent {
    var spikeText: String? {
        switch kind {
        case .text(let body, _), .notice(let body, _), .emote(let body, _): body
        default: nil
        }
    }
}

/// The fault proxy's traffic counters.
private enum ScaleStageProxy {
    static func reset() async { _ = await call("DELETE") }
    static func requests(_ part: String) async -> Int {
        (await call("GET") as? [String: [String: Any]] ?? [:]).filter { part.isEmpty || $0.key.contains(part) }.values.reduce(0) { $0 + ($1["requests"] as? Int ?? 0) }
    }

    private static func call(_ method: String) async -> Any? {
        guard let url = URL(string: (env["HALO_FAULT_CONTROL"] ?? "") + "/stats") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
