import Foundation
import HaloFoundation
import MatrixRustSDK
import Testing

/// V-RS-7 decision (D73): classic `/sync` is the source of unread evidence. This checks, against `infra/dev`, that the pinned
/// SDK exposes what the policy needs per room when it runs classic sync (`Client.syncOnceV2`, sliding sync off): the
/// server's counts, mentions, the SDK's own counts, the user's own receipt (also one written from another device) and the
/// latest event. Needs `HALO_DEV_PEER_USER/PASSWORD/UNREAD_ROOM` (infra/dev/create-fixtures.py).
private let env = ProcessInfo.processInfo.environment
private let configured = ["HALO_DEV_SERVER", "HALO_DEV_USER", "HALO_DEV_PASSWORD", "HALO_DEV_PEER_USER", "HALO_DEV_PEER_PASSWORD", "HALO_DEV_UNREAD_ROOM"]
    .allSatisfy { env[$0] != nil }

@Suite("Classic sync evidence (V-RS-7)", .serialized, .enabled(if: configured, "needs the peer fixtures"))
struct ClassicSyncEvidenceTests {
    private struct Http {
        let server: String
        func call(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: try #require(URL(string: server + "/_matrix/client/v3" + path)))
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, _) = try await URLSession.shared.data(for: request)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func login(_ user: String, _ password: String) async throws -> String {
            let r = try await call("POST", "/login", body: [
                "type": "m.login.password", "identifier": ["type": "m.id.user", "user": user], "password": password, "initial_device_display_name": "evidence"])
            return try #require(r["access_token"] as? String)
        }
        func send(_ room: String, _ token: String, _ body: String, mention: String? = nil) async throws -> String {
            var content: [String: Any] = ["msgtype": "m.text", "body": body]
            if let mention { content["m.mentions"] = ["user_ids": [mention]] }
            let txn = UUID().uuidString
            let r = try await call("PUT", "/rooms/\(room.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? room)/send/m.room.message/\(txn)", token: token, body: content)
            return try #require(r["event_id"] as? String)
        }
    }

    private func counts(_ room: Room) async throws -> (server: UInt64, highlight: UInt64, sdk: UInt64, sdkMentions: UInt64) {
        let info = try await room.roomInfo()
        return (info.notificationCount, info.highlightCount, info.numUnreadMessages, info.numUnreadMentions)
    }

    /// Syncs until `condition` holds for the room's info (or gives up after ~20 s).
    private func settle(_ client: Client, _ room: Room, _ condition: @escaping (RoomInfo) -> Bool) async throws -> RoomInfo {
        for _ in 0..<20 {
            _ = try await client.syncOnceV2(settings: SyncSettingsV2(timeoutMs: 1000, fullState: false))
            let info = try await room.roomInfo()
            if condition(info) { return info }
        }
        return try await room.roomInfo()
    }

    @Test("with classic sync the SDK serves server counts, mentions, SDK counts, the own receipt and the latest event per room")
    func evidence() async throws {
        let server = try #require(env["HALO_DEV_SERVER"])
        let user = try #require(env["HALO_DEV_USER"])
        let http = Http(server: server)
        let me = "@\(user):halo.localhost"
        let roomID = try #require(env["HALO_DEV_UNREAD_ROOM"])
        let peerToken = try await http.login(try #require(env["HALO_DEV_PEER_USER"]), try #require(env["HALO_DEV_PEER_PASSWORD"]))
        let otherDevice = try await http.login(user, try #require(env["HALO_DEV_PASSWORD"]))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-classic-\(UUID().uuidString)")
        let data = dir.appendingPathComponent("data"), cache = dir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let client = try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: server)
            .sessionPaths(dataPath: data.path, cachePath: cache.path)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: data.path, cachePath: cache.path))
            .slidingSyncVersionBuilder(versionBuilder: .none)
            .build()
        try await client.login(username: user, password: try #require(env["HALO_DEV_PASSWORD"]), initialDeviceName: "classic", deviceId: nil)
        defer { Task { try? await client.logout() } }

        _ = try await client.syncOnceV2(settings: SyncSettingsV2(timeoutMs: 1000, fullState: false))
        let room = try #require(try client.getRoom(roomId: roomID))
        // Start from a read room: a receipt from another device at the newest event.
        let marker = try await http.send(roomID, peerToken, "baseline")
        _ = try await http.call("POST", "/rooms/\(roomID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? roomID)/receipt/m.read/\(marker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? marker)", token: otherDevice, body: [:])
        var info = try await settle(client, room) { $0.notificationCount == 0 }
        #expect(info.notificationCount == 0 && info.highlightCount == 0, "server counts after a receipt from another device")
        let ownReceipt = try await room.loadUserReceipt(receiptType: .read, thread: .unthreaded, userId: me)
        #expect(ownReceipt?.eventId == marker, "own receipt from another device")

        // Three messages and one mention from the peer.
        for i in 1...3 { _ = try await http.send(roomID, peerToken, "plain \(i)") }
        let mention = try await http.send(roomID, peerToken, "hello", mention: me)
        info = try await settle(client, room) { $0.notificationCount >= 4 }
        #expect(info.notificationCount == 4, "server notification count over classic sync: \(info.notificationCount)")
        #expect(info.highlightCount == 1, "server highlight count over classic sync: \(info.highlightCount)")
        #expect(info.numUnreadMessages >= 4, "the SDK's own count: \(info.numUnreadMessages)")
        #expect(info.numUnreadMentions >= 1, "the SDK's own mention count: \(info.numUnreadMentions)")
        let latest = await room.latestEvent()
        if case .remote(_, _, let isOwn, _, _) = latest { #expect(!isOwn) } else { Issue.record("latest event is not a remote event: \(latest)") }

        // Reading on another device clears them within a sync, including the SDK's own counts.
        _ = try await http.call("POST", "/rooms/\(roomID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? roomID)/receipt/m.read/\(mention.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? mention)", token: otherDevice, body: [:])
        info = try await settle(client, room) { $0.notificationCount == 0 }
        #expect(info.notificationCount == 0 && info.highlightCount == 0, "server counts cleared by the other device's receipt")
        let after = try await counts(room)
        #expect(after.sdk == 0 && after.sdkMentions == 0, "the SDK's own counts after the other device read: \(after)")
        let receipt = try await room.loadUserReceipt(receiptType: .read, thread: .unthreaded, userId: me)
        #expect(receipt?.eventId == mention)
    }
}
