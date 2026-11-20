import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import MatrixRustSDK
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
            if !load.packs.isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        let pack = try #require(load.packs.first, "no pack read: option A of V-ST-1 does not work, failedSources=\(load.failedSources)")
        #expect(pack.ref == PackRef(room: room, stateKey: "cats") && pack.displayName == "Cats" && pack.source == .userEnabled)
        #expect(pack.stickers.map(\.shortcode) == ["dance", "wave"])
        #expect(pack.stickers.allSatisfy { $0.image != nil })

        // The same pack, found as the current room's pack.
        let asRoomPack = try await packs.packs(currentRoom: room)
        #expect(asRoomPack.packs.count == 1)  // not listed twice

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
}
