import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
import Synchronization
import Testing
@testable import HaloMatrixAdapter

/// Runs the shared port contracts against a real homeserver (docs/testing/INTEGRATION_TESTS.md §3).
/// Enabled only when `HALO_DEV_SERVER`, `HALO_DEV_USER` and `HALO_DEV_PASSWORD` are set (an account on
/// `infra/dev`, see infra/dev/README.md); otherwise the tests are reported as skipped, never as passed.
private let env = ProcessInfo.processInfo.environment
private let configured = env["HALO_DEV_SERVER"] != nil && env["HALO_DEV_USER"] != nil && env["HALO_DEV_PASSWORD"] != nil

/// Real I/O needs a deadline: a contract that waits for a stream must fail, not hang.
private func within<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ContractViolation("timed out after \(seconds) s")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? { throw ContractViolation("no result") }()
    }
}

@Suite("Adapter contracts against infra/dev", .serialized, .enabled(if: configured, "needs HALO_DEV_SERVER/USER/PASSWORD"))
struct AdapterContractTests {
    private func port() -> MatrixSessionPort {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-contract-\(UUID().uuidString)")
        return MatrixSessionPort(baseDirectory: dir)
    }

    @Test("SessionPortContract")
    func session() async throws {
        let account = FakeSessionPort.Account(localpart: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "")
        try await SessionPortContract.verify(port(), server: env["HALO_DEV_SERVER"] ?? "", account: account)
    }

    @Test("RoomListPortContract (the account must be in HALO_DEV_ROOMS rooms)")
    func roomList() async throws {
        let session = port()
        let server = env["HALO_DEV_SERVER"] ?? ""
        let details = try await session.loginDetails(server: server)
        let stored = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "",
                deviceDisplayName: "contract"),
            on: details)
        _ = stored
        let expected = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await MatrixSyncPort(session: session).start()
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: expected) }
        try await session.logout()
    }

    @Test("TimelinePortContract (HALO_DEV_TIMELINE_ROOM holds first, second, a notice, waves and a redacted message)", .enabled(if: env["HALO_DEV_TIMELINE_ROOM"] != nil))
    func timeline() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        // The client only knows a room once sync has delivered it.
        let rooms = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await MatrixSyncPort(session: session).start()
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: rooms) }
        let timeline = MatrixTimelinePort(session: session)
        let room = try RoomID(env["HALO_DEV_TIMELINE_ROOM"] ?? "")
        try await within(seconds: 60) { try await TimelinePortContract.verify(timeline, room: room, expectedBodies: ["first", "second", "a notice", "waves"]) }
        try await within(seconds: 60) { try await TimelinePortContract.verifySend(timeline, room: room, text: "sent by the contract \(UUID().uuidString.prefix(8))") }
        try await within(seconds: 90) { try await TimelinePortContract.verifyInteractions(timeline, room: room, text: "interaction \(UUID().uuidString.prefix(8))") }
        try await TimelinePortContract.verifyUnknownRoom(timeline, room: try RoomID("!does-not-exist:localhost"))
        try await session.logout()
    }

    @Test("Stickers (HALO_DEV_STICKER_ROOM holds m.room.image_pack \"cats\" with wave and dance, enabled in m.image_pack.rooms)", .enabled(if: env["HALO_DEV_STICKER_ROOM"] != nil))
    func stickers() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let room = try RoomID(env["HALO_DEV_STICKER_ROOM"] ?? "")

        // V-ST-1 option A: is the image-pack state readable through the SDK? Poll: the room arrives with sync.
        let packs = MatrixStickerPackPort(session: session)
        var load = StickerPackLoad(packs: [], failedSources: 0)
        for _ in 0..<60 {
            load = try await packs.packs(currentRoom: nil)
            if load.packs.contains(where: { $0.ref.stateKey == "cats" }) { break }
            try await Task.sleep(for: .seconds(1))
        }
        // The account may hold more enabled packs (each `createPack` run adds one); this test is about the fixture's.
        let cats = PackRef(room: room, stateKey: "cats")
        let pack = try #require(load.packs.first { $0.ref == cats }, "fixture pack not read, failedSources=\(load.failedSources)")
        #expect(pack.ref == PackRef(room: room, stateKey: "cats") && pack.displayName == "Cats" && pack.source == .userEnabled)
        #expect(pack.stickers.map(\.shortcode) == ["dance", "wave"])
        #expect(pack.stickers.allSatisfy { $0.image != nil })

        // The same pack, found as the current room's pack.
        let asRoomPack = try await packs.packs(currentRoom: room)
        #expect(asRoomPack.packs.filter { $0.ref == cats }.count == 1)  // not listed twice
        #expect(asRoomPack.failedSources == 0)

        // Prefs round trip through account data.
        let prefsPort = MatrixStickerPrefsPort(session: session)
        var prefs = StickerPrefs()
        prefs.toggleFavourite(pack.stickers[0].ref)
        prefs.recordUse(pack.stickers[1].ref, at: Date(timeIntervalSince1970: 1_700_000_000))
        do { try await prefsPort.save(prefs) } catch { Issue.record("prefs save failed: \(error)") }
        // The SDK serves account data from its store, which a sync fills in; wait for the write to come back.
        var loaded: StickerPrefs?
        for _ in 0..<30 {
            do { loaded = try await prefsPort.load() } catch { Issue.record("prefs load failed: \(error)"); break }
            if loaded == prefs { break }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(loaded == prefs)

        // Sending an m.sticker shows up in the timeline as a sticker.
        let timeline = try await MatrixTimelinePort(session: session).open(room: room)
        let stream = timeline.items()
        try await timeline.sendSticker(pack.stickers[1])
        let seen: Bool = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in stream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, case .sticker(let body, _) = event.kind, body == "Waving" { return true }
                }
            }
            return false
        }
        #expect(seen)
        await timeline.close()
        try await session.logout()
    }

    @Test("Mentions, members and unknown local echoes (uses HALO_DEV_STICKER_ROOM as a scratch room)", .enabled(if: env["HALO_DEV_STICKER_ROOM"] != nil))
    func mentionsAndEchoes() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let room = try RoomID(env["HALO_DEV_STICKER_ROOM"] ?? "")
        var timeline: (any TimelineSession)?
        for _ in 0..<60 {
            if let opened = try? await MatrixTimelinePort(session: session).open(room: room) { timeline = opened; break }
            try await Task.sleep(for: .seconds(1))
        }
        let opened = try #require(timeline)
        let stream = opened.items()

        // The room has one member, the user; members() excludes the user.
        #expect(try await opened.members().isEmpty)

        // A mention becomes a link in the formatted body. The name is hostile (display names are chosen by their owner):
        // it must come out as plain text, not as HTML, emphasis or a second link.
        let me = try UserID("@\(env["HALO_DEV_USER"] ?? ""):halo.localhost")
        let marker = UUID().uuidString.prefix(6)
        let hostile = "T<b>*x*</b>](https://phish)"
        try await opened.send(text: "hello @\(hostile) \(marker)", mentions: [Mention(user: me, name: hostile)])
        let body: String? = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in stream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, event.isOwn, event.eventID != nil, case .text(let text, _) = event.kind, text.contains(String(marker)) {
                        return event.formattedBody
                    }
                }
            }
            return nil
        }
        #expect(body?.contains("https://matrix.to/#/\(me.rawValue)") == true, "formatted body: \(body ?? "nil")")
        #expect(body?.contains("<b>") == false && body?.contains("<em>") == false && body?.contains("href=\"https://phish") == false,
                "formatted body: \(body ?? "nil")")

        // Retrying or aborting an echo that doesn't exist reports an error instead of crashing.
        await #expect(throws: HaloError.notFound) { try await opened.retrySend(localID: "no-such-echo") }
        await #expect(throws: HaloError.notFound) { try await opened.abortSend(localID: "no-such-echo") }
        await opened.close()
        try await session.logout()
    }

    @Test("Sending an image (uses HALO_DEV_STICKER_ROOM as a scratch room)", .enabled(if: env["HALO_DEV_STICKER_ROOM"] != nil))
    func sendImage() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let room = try RoomID(env["HALO_DEV_STICKER_ROOM"] ?? "")
        var timeline: (any TimelineSession)?
        for _ in 0..<60 {
            if let opened = try? await MatrixTimelinePort(session: session).open(room: room) { timeline = opened; break }
            try await Task.sleep(for: .seconds(1))
        }
        let opened = try #require(timeline)
        let stream = opened.items()
        // A 1×1 PNG.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let name = "contract-\(UUID().uuidString.prefix(6)).png"
        try await opened.sendImage(OutgoingImage(data: png, filename: name, mimeType: "image/png", width: 1, height: 1))
        let found: MediaAttachment? = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in stream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, event.isOwn, event.eventID != nil, case .media(let attachment) = event.kind, attachment.body == name { return attachment }
                }
            }
            return nil
        }
        let attachment = try #require(found)
        #expect(attachment.kind == .image && attachment.source != nil && attachment.width == 1 && attachment.height == 1)
        // The bytes come back through the media port.
        let data = try await MatrixMediaPort(session: session).thumbnail(try #require(attachment.source), width: 64, height: 64)
        #expect(!data.isEmpty)
        await #expect(throws: HaloError.invalidInput("NOT_AN_IMAGE")) {
            try await opened.sendImage(OutgoingImage(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain", width: nil, height: nil))
        }
        await opened.close()
        try await session.logout()
    }

    @Test("Creating a sticker pack (creates a room on the dev server)", .enabled(if: env["HALO_DEV_STICKER_ROOM"] != nil))
    func createPack() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let name = "Contract \(UUID().uuidString.prefix(5))"
        let images = [
            NewStickerImage(data: png, mimeType: "image/png", width: 1, height: 1, shortcode: "one"),
            NewStickerImage(data: png, mimeType: "image/png", width: 1, height: 1, shortcode: "two", body: "Second"),
        ]
        let creation = MatrixStickerPackCreationPort(session: session)
        let ticks = Mutex<[Int]>([])
        let ref = try await within(seconds: 90) { try await creation.createPack(name: name, images: images) { done, _ in ticks.withLock { $0.append(done) } } }
        #expect(ticks.withLock { $0 } == [1, 2])

        // Read it back like the panel does.
        let reader = MatrixStickerPackPort(session: session)
        var pack: StickerPack?
        for _ in 0..<30 {
            pack = try await reader.packs(currentRoom: nil).packs.first { $0.ref == ref }
            if pack != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let found = try #require(pack, "the created pack is not listed in m.image_pack.rooms")
        #expect(found.displayName == name && found.stickers.map(\.shortcode) == ["one", "two"] && found.offersStickers)
        #expect(found.stickers[1].body == "Second" && found.stickers.allSatisfy { $0.url.hasPrefix("mxc://") })
        // The images were uploaded: their bytes come back.
        let data = try await MatrixMediaPort(session: session).thumbnail(try #require(found.stickers[0].image), width: 32, height: 32)
        #expect(!data.isEmpty)
        // The pack room is listed to be hidden from the room list.
        let hiding = MatrixHiddenRoomsPort(session: session)
        var hidden: Set<RoomID> = []
        for _ in 0..<30 {
            hidden = await hiding.hiddenRooms()
            if hidden.contains(ref.room) { break }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(hidden.contains(ref.room))
        // Invalid input is refused before anything is uploaded.
        await #expect(throws: HaloError.invalidInput("DUPLICATE_SHORTCODE")) {
            _ = try await creation.createPack(name: "x", images: [images[0], images[0]]) { _, _ in }
        }
        // Leave the pack room again: later tests expect the account to be in HALO_DEV_ROOMS rooms.
        try await (try await session.room(ref.room)).leave()
        try await session.logout()
    }

    @Test("SyncPortContract")
    func sync() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        let sync = MatrixSyncPort(session: session)
        try await within(seconds: 60) { try await SyncPortContract.verify(sync) }
        try await session.logout()
    }

    @Test("MediaPortContract (the timeline room holds one image, blue.png)", .enabled(if: env["HALO_DEV_TIMELINE_ROOM"] != nil))
    func media() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let rooms = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: rooms) }

        // Find the image through the timeline, like the UI does.
        let timeline = try await MatrixTimelinePort(session: session).open(room: try RoomID(env["HALO_DEV_TIMELINE_ROOM"] ?? ""))
        let attachment: MediaAttachment? = try await within(seconds: 60) {
            let pagination = Task { for _ in 0..<5 { if (try? await timeline.paginateBackwards(count: 20)) == true { break } } }
            defer { pagination.cancel() }
            var items: [HaloDomain.TimelineItem] = []
            for await diff in timeline.items() {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, case .media(let media) = event.kind, media.kind == .image { return media }
                }
            }
            return nil
        }
        let found = try #require(attachment)
        #expect(found.body == "blue.png" && found.width == 64 && found.height == 48)
        let existing = try #require(found.source)
        let missing = MediaRef(token: try MediaSource.fromUrl(url: "mxc://halo.localhost/doesNotExist00000000000").toJson())
        try await within(seconds: 60) { try await MediaPortContract.verify(MatrixMediaPort(session: session), existing: existing, missing: missing) }
        try await session.logout()
    }

    @Test("ReadMarkerPort: receipts (public and private) and the fully-read marker are accepted for a confirmed event", .enabled(if: env["HALO_DEV_TIMELINE_ROOM"] != nil))
    func readMarkers() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(
                username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let rooms = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: rooms) }
        let room = try RoomID(env["HALO_DEV_TIMELINE_ROOM"] ?? "")
        let timeline = try await MatrixTimelinePort(session: session).open(room: room)
        let eventID: EventID? = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in timeline.items() {
                try ListReducer.apply(diff, to: &items)
                for item in items { if case .event(let event) = item.content, let id = event.eventID { return id } }
            }
            return nil
        }
        let event = try #require(eventID)
        let markers = MatrixReadMarkerPort(session: session)
        try await markers.sendReceipt(room: room, event: event, isPrivate: false)
        try await markers.sendReceipt(room: room, event: event, isPrivate: true)
        try await markers.setFullyRead(room: room, event: event)
        await #expect(throws: HaloError.notFound) {
            try await markers.sendReceipt(room: try RoomID("!unknown:halo.localhost"), event: event, isPrivate: false)
        }
        // Room-list actions: the room's latest event is resolved by the adapter; the unread flag round-trips.
        #expect(try await markers.markRoomRead(room: room, isPrivate: false) != nil)
        try await markers.setMarkedUnread(room: room, true)
        try await markers.setMarkedUnread(room: room, false)
        try await session.logout()
    }

    @Test("EncryptionPortContract: recovery set up on one device unlocks a second one (needs a throwaway account in HALO_DEV_E2EE_USER/PASSWORD)", .enabled(if: env["HALO_DEV_E2EE_USER"] != nil && env["HALO_DEV_E2EE_PASSWORD"] != nil))
    func encryption() async throws {
        // A throwaway account (create it with infra/dev/create-user.sh): recovery can be enabled on it only once.
        let user = try #require(env["HALO_DEV_E2EE_USER"])
        let password = try #require(env["HALO_DEV_E2EE_PASSWORD"])
        let server = env["HALO_DEV_SERVER"] ?? ""

        let first = port()
        let details = try await first.loginDetails(server: server)
        _ = try await first.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "e2ee-1"), on: details)
        try await MatrixSyncPort(session: first).start()
        let key = try await within(seconds: 90) { try await MatrixEncryptionPort(session: first).enableRecovery() }

        // Optional: leave the key where a manual UI check can read it (throwaway account only).
        if let out = env["HALO_DEV_E2EE_KEY_OUT"] { try key.write(toFile: out, atomically: true, encoding: .utf8) }

        let second = port()
        _ = try await second.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "e2ee-2"), on: details)
        try await MatrixSyncPort(session: second).start()
        let unverified = MatrixEncryptionPort(session: second)
        try await within(seconds: 90) { try await EncryptionPortContract.verifyRecovery(unverified, recoveryKey: key) }
        try await first.logout()
        try await second.logout()
    }

    /// The pushers the account has on the server, read with a plain HTTP login of its own (not through the adapter).
    private func pushkeys() async throws -> [String] {
        let server = try #require(env["HALO_DEV_SERVER"])
        var login = URLRequest(url: try #require(URL(string: server + "/_matrix/client/v3/login")))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "m.login.password", "identifier": ["type": "m.id.user", "user": env["HALO_DEV_USER"] ?? ""],
            "password": env["HALO_DEV_PASSWORD"] ?? "", "initial_device_display_name": "pushers",
        ])
        let (loginData, _) = try await URLSession.shared.data(for: login)
        let token = try #require((try JSONSerialization.jsonObject(with: loginData) as? [String: Any])?["access_token"] as? String)
        var request = URLRequest(url: try #require(URL(string: server + "/_matrix/client/v3/pushers")))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let pushers = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["pushers"] as? [[String: Any]] ?? []
        return pushers.compactMap { $0["pushkey"] as? String }
    }

    @Test("PushPort: register creates the pusher on the server, unregister (deletePusher) removes it and is repeatable")
    func pusher() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        let push = MatrixPushPort(session: session)
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let pushkey = token.map { String(format: "%02x", $0) }.joined()
        let appID = "one.mbm.halo.contract"
        try await push.register(deviceToken: token, appID: appID, gatewayURL: try #require(URL(string: "http://localhost:5000/_matrix/push/v1/notify")), deviceName: "contract")
        #expect(try await pushkeys().contains(pushkey))
        try await push.unregister(deviceToken: token, appID: appID)
        #expect(try await !pushkeys().contains(pushkey))
        try await push.unregister(deviceToken: token, appID: appID)  // already gone: must not fail the sign-out
        try await session.logout()
    }

    /// S01/S02/S09-style scenario with the real stack: the adapter's room list over classic sync feeds `ReadStatePolicy`.
    /// Peer messages and a mention make the room need attention (`.mentions(1)`); a read receipt from another device of the same
    /// account clears it within a sync; `m.marked_unread` from the other device brings attention back (E5).
    @Test("Policy over the adapter's real inputs (peer messages, other-device receipt, marked unread)",
          .enabled(if: env["HALO_DEV_PEER_USER"] != nil && env["HALO_DEV_UNREAD_ROOM"] != nil))
    func policyOverRealInputs() async throws {
        let server = env["HALO_DEV_SERVER"] ?? ""
        let user = env["HALO_DEV_USER"] ?? "", password = env["HALO_DEV_PASSWORD"] ?? ""
        let me = "@\(user):halo.localhost"
        let roomID = env["HALO_DEV_UNREAD_ROOM"] ?? ""
        let http = PolicyHttp(server: server, me: me, roomID: roomID)
        let peer = try await http.login(env["HALO_DEV_PEER_USER"] ?? "", env["HALO_DEV_PEER_PASSWORD"] ?? "")
        let other = try await http.login(user, password)
        // Start from read: the other device's receipt at a fresh event.
        let baseline = try await http.send(peer, "policy baseline")
        try await http.read(other, baseline)

        let session = port()
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "contract"), on: details)
        try await MatrixSyncPort(session: session).start()
        let rooms = MatrixRoomListPort(session: session)
        let target = try RoomID(roomID)

        let observed: [String] = try await within(seconds: 120) {
            var items: [RoomSummary] = []
            var log: [String] = []
            var iterator = rooms.rooms(filter: .all).makeAsyncIterator()
            func next(until done: (RoomReadState) -> Bool, _ label: String) async throws {
                while let diff = await iterator.next() {
                    try RoomListReducer.apply(diff, to: &items)
                    guard let room = items.first(where: { $0.id == target }) else { continue }
                    let state = ReadStatePolicy.evaluate(RoomReadInputs(
                        roomID: room.id, membership: room.membership, isEncrypted: room.isEncrypted, counts: room.read,
                        latestEvent: room.latestEvent, localIntent: room.ownReadThrough))
                    if done(state) { log.append("\(label): attention \(state.attention), \(state.display), reasons \(state.reasons.map(\.rawValue).sorted())"); return }
                }
                throw ContractViolation("stream ended before: \(label)")
            }
            try await next(until: { !$0.attention }, "read baseline")
            for i in 1...3 { _ = try await http.send(peer, "policy plain \(i)") }
            _ = try await http.send(peer, "policy hello", mention: true)
            try await next(until: { $0.attention && $0.display == .mentions(1) }, "after peer messages and a mention")
            let last = try await http.send(peer, "policy last")
            try await http.read(other, last)
            try await next(until: { !$0.attention }, "after the other device read")
            try await http.markUnread(other, true)
            try await next(until: { $0.attention && $0.reasons.contains(.markedUnread) }, "after the other device marked it unread")
            try await http.markUnread(other, false)
            try await next(until: { !$0.attention }, "after the flag was cleared")
            return log
        }
        for line in observed { print("POLICY \(line)") }
        try await session.logout()
    }
}

/// Minimal Matrix client-server calls for the policy scenario (the peer user and the account's second device).
private struct PolicyHttp: Sendable {
    let server: String, me: String, roomID: String
    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
    private func call(_ method: String, _ path: String, token: String? = nil, body: [String: String]) async throws -> [String: String] {
        guard let url = URL(string: server + "/_matrix/client/v3" + path) else { throw ContractViolation("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return json.compactMapValues { $0 as? String }
    }
    func login(_ name: String, _ password: String) async throws -> String {
        let r = try await call("POST", "/login", body: ["type": "m.login.password", "user": name, "password": password, "initial_device_display_name": "policy"])
        guard let token = r["access_token"] else { throw ContractViolation("login failed") }
        return token
    }
    func send(_ token: String, _ text: String, mention: Bool = false) async throws -> String {
        guard let url = URL(string: server + "/_matrix/client/v3/rooms/\(enc(roomID))/send/m.room.message/\(UUID().uuidString)") else { throw ContractViolation("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        var content: [String: Any] = ["msgtype": "m.text", "body": text]
        if mention { content["m.mentions"] = ["user_ids": [me]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: content)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["event_id"] as? String else { throw ContractViolation("send failed") }
        return id
    }
    func read(_ token: String, _ event: String) async throws {
        _ = try await call("POST", "/rooms/\(enc(roomID))/receipt/m.read/\(enc(event))", token: token, body: [:])
    }
    func markUnread(_ token: String, _ unread: Bool) async throws {
        guard let url = URL(string: server + "/_matrix/client/v3/user/\(enc(me))/rooms/\(enc(roomID))/account_data/m.marked_unread") else { throw ContractViolation("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["unread": unread])
        _ = try await URLSession.shared.data(for: request)
    }
}
