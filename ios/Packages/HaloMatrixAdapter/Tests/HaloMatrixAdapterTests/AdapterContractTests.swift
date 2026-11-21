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
        // `infra/dev/add-animated-sticker.py` may have added "spin" (an animated GIF): the two fixtures must be there, in order.
        #expect(pack.stickers.map(\.shortcode).filter { $0 != "spin" } == ["dance", "wave"])
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
        // A pack entry without `info` (allowed by MSC2545) must still arrive as a sticker, not as an unsupported event.
        let bare = pack.stickers[1]
        try await timeline.sendSticker(Sticker(pack: bare.pack, shortcode: bare.shortcode, body: "Bare wave", url: bare.url, info: nil))
        let seen: Bool = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            var found: Set<String> = []
            for await diff in stream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, case .sticker(let body, _) = event.kind { found.insert(body) }
                }
                if found.isSuperset(of: ["Waving", "Bare wave"]) { return true }
            }
            return false
        }
        #expect(seen)
        await timeline.close()
        try await session.logout()
    }

    @Test("warm() prepares a room's timeline with its first page; open() takes it, an open room isn't prepared again, dropWarm() lets go")
    func warmTimelines() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let rooms = Int(env["HALO_DEV_ROOMS"] ?? "0") ?? 0
        try await within(seconds: 60) { try await RoomListPortContract.verify(MatrixRoomListPort(session: session), expectedRoomCount: rooms) }
        let room = try RoomID(env["HALO_DEV_TIMELINE_ROOM"] ?? "")
        let timelines = MatrixTimelinePort(session: session)
        await timelines.warm([room])
        #expect(timelines.isWarm(room))
        let opened = try await timelines.open(room: room)
        #expect(!timelines.isWarm(room))
        // The prepared timeline already holds events: the first state shows one without another pagination.
        let shown = try await within(seconds: 30) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in opened.items() {
                try ListReducer.apply(diff, to: &items)
                if items.contains(where: { if case .event = $0.content { true } else { false } }) { return true }
            }
            return false
        }
        #expect(shown)
        await timelines.warm([room])
        #expect(!timelines.isWarm(room))  // on screen: not prepared again behind it
        await opened.close()
        await timelines.warm([room])
        #expect(timelines.isWarm(room))
        await timelines.dropWarm()
        #expect(!timelines.isWarm(room))
        try await session.logout()
    }

    @Test("Legacy im.ponies packs are read as read-only legacy packs (V-ST-3; creates a room and cleans up after itself)")
    func legacyPacks() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let client = try await session.signedInClient()
        let roomID = try await client.createRoom(request: CreateRoomParameters(name: "Legacy pack fixture", isEncrypted: false, visibility: .private, preset: .privateChat))
        let ref = PackRef(room: try RoomID(roomID), stateKey: "oldcats")
        var room: Room?
        for _ in 0..<30 {
            if let known = try? await session.room(ref.room) { room = known; break }
            try await Task.sleep(for: .seconds(1))
        }
        let local = try #require(room)
        let pack = #"{"pack":{"display_name":"Old cats","usage":["sticker"]},"images":{"wave":{"url":"mxc://halo.localhost/legacywave0000000000"}}}"#
        _ = try await local.sendStateEventRaw(eventType: "im.ponies.room_emotes", stateKey: ref.stateKey, content: pack, requestConfigOverride: nil)
        try await client.setAccountData(eventType: "im.ponies.emote_rooms", content: #"{"rooms":{"\#(roomID)":{"oldcats":{}}}}"#)

        let packs = MatrixStickerPackPort(session: session)
        var found: StickerPack?
        for _ in 0..<30 {
            found = try await packs.packs(currentRoom: nil).packs.first { $0.ref == ref }
            if found != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let legacy = try #require(found, "legacy pack not read")
        #expect(legacy.source == .legacy && legacy.displayName == "Old cats" && legacy.stickers.map(\.shortcode) == ["wave"])
        // As the current room's pack (whole-state path) it is found too, still once.
        let asRoom = try await packs.packs(currentRoom: ref.room)
        #expect(asRoom.packs.filter { $0.ref == ref }.count == 1)
        // Leave no room or listing behind (the other contracts expect the account's fixed room count); before the logout.
        try? await client.setAccountData(eventType: "im.ponies.emote_rooms", content: "{}")
        try? await local.leave()
        try? await local.forget()
        try await session.logout()
    }

    @Test("Room details, members, notification mode and leaving (ROOM_MANAGEMENT; creates a room and cleans up after itself)")
    func roomManagement() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let client = try await session.signedInClient()
        let roomID = try RoomID(try await client.createRoom(request: CreateRoomParameters(name: "Room mgmt fixture", topic: "A topic", isEncrypted: false, visibility: .private, preset: .privateChat)))
        for _ in 0..<30 {
            if (try? await session.room(roomID)) != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let rooms = MatrixRoomPort(session: session)
        var info = try await rooms.details(roomID)
        for _ in 0..<30 where info.topic == nil {  // the room's state arrives with a sync
            try await Task.sleep(for: .seconds(1))
            info = try await rooms.details(roomID)
        }
        #expect(info.name == "Room mgmt fixture" && info.topic == "A topic" && info.isEncrypted == false)
        let members = try await rooms.members(roomID, limit: 50)
        #expect(members.count == 1 && members[0].role == .administrator)
        for mode in RoomNotificationChoice.allCases {
            try await rooms.setNotificationMode(mode, in: roomID)
            var seen = try await rooms.details(roomID).notificationMode
            for _ in 0..<30 where seen != mode {  // the push rule reaches the SDK with a sync
                try await Task.sleep(for: .seconds(1))
                seen = try await rooms.details(roomID).notificationMode
            }
            #expect(seen == mode)
        }
        // The creator may edit and invite; edits read back after a sync.
        for _ in 0..<30 where !(info.canEditDetails && info.canInvite) {  // power levels arrive with the room state
            try await Task.sleep(for: .seconds(1))
            info = try await rooms.details(roomID)
        }
        #expect(info.canEditDetails && info.canInvite, "creator permissions not read")
        try await rooms.setDetails(name: "Renamed fixture", topic: "New topic", in: roomID)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try await rooms.setAvatar(mimeType: "image/png", data: png, in: roomID)
        try await rooms.removeAvatar(in: roomID)
        var edited = try await rooms.details(roomID)
        for _ in 0..<30 where edited.name != "Renamed fixture" || edited.topic != "New topic" {
            try await Task.sleep(for: .seconds(1))
            edited = try await rooms.details(roomID)
        }
        #expect(edited.name == "Renamed fixture" && edited.topic == "New topic")
        if let peerName = env["HALO_DEV_PEER_USER"] {
            try await rooms.invite([try UserID("@\(peerName):halo.localhost")], to: roomID)
            var invited = try await rooms.members(roomID, limit: 50)
            for _ in 0..<30 where !invited.contains(where: \.isInvited) {
                try await Task.sleep(for: .seconds(1))
                invited = try await rooms.members(roomID, limit: 50)
            }
            #expect(invited.contains { $0.isInvited })
        }
        // Favourite tag: set, then the room list reports it; cleared again.
        func isFavourite() async -> Bool? {
            var iterator = MatrixRoomListPort(session: session).rooms(filter: .all).makeAsyncIterator()
            var items: [RoomSummary] = []
            guard let diff = await iterator.next() else { return nil }
            try? RoomListReducer.apply(diff, to: &items)
            return items.first { $0.id == roomID }?.isFavourite
        }
        for target in [true, false] {
            try await rooms.setFavourite(target, in: roomID)
            var seen = await isFavourite()
            for _ in 0..<30 where seen != target {
                try await Task.sleep(for: .seconds(1))
                seen = await isFavourite()
            }
            #expect(seen == target, "favourite \(target) not reported")
        }
        try await rooms.leave(roomID)
        if let left = try? await session.room(roomID) { try? await left.forget() }
        try await session.logout()
    }

    @Test("Invitations: the room arrives as invited, accepting joins it, declining removes it (a peer account creates the rooms)",
          .enabled(if: env["HALO_DEV_PEER_USER"] != nil))
    func invitations() async throws {
        let server = env["HALO_DEV_SERVER"] ?? ""
        let user = env["HALO_DEV_USER"] ?? ""
        let peer = PeerInviter(server: server)
        try await peer.login(env["HALO_DEV_PEER_USER"] ?? "", env["HALO_DEV_PEER_PASSWORD"] ?? "")
        let toAccept = try RoomID(try await peer.createRoom(name: "Invite accept fixture", invite: "@\(user):halo.localhost"))
        let toDecline = try RoomID(try await peer.createRoom(name: "Invite decline fixture", invite: "@\(user):halo.localhost"))

        let session = port()
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(PasswordCredentials(username: user, password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"), on: details)
        try await MatrixSyncPort(session: session).start()
        let list = MatrixRoomListPort(session: session)
        let rooms = MatrixRoomPort(session: session)
        func membership(_ id: RoomID) async -> HaloDomain.Membership? {
            var iterator = list.rooms(filter: .all).makeAsyncIterator()
            var items: [RoomSummary] = []
            while let diff = await iterator.next() {
                try? RoomListReducer.apply(diff, to: &items)
                return items.first { $0.id == id }?.membership
            }
            return nil
        }
        func waitFor(_ id: RoomID, _ expected: HaloDomain.Membership?) async throws -> HaloDomain.Membership? {
            var seen = await membership(id)
            for _ in 0..<30 where seen != expected {
                try await Task.sleep(for: .seconds(1))
                seen = await membership(id)
            }
            return seen
        }
        #expect(try await waitFor(toAccept, .invited) == .invited)
        #expect(try await waitFor(toDecline, .invited) == .invited)
        let preview = try await rooms.invitePreview(toDecline)
        #expect(preview.name == "Invite decline fixture")
        #expect(preview.memberCount.map { $0 >= 1 } ?? true)
        try await rooms.acceptInvite(toAccept)
        #expect(try await waitFor(toAccept, .joined) == .joined)
        try await rooms.declineInvite(toDecline)
        #expect(try await waitFor(toDecline, nil) == nil)
        try await rooms.leave(toAccept)  // leave no room behind: the other contracts expect a fixed room count
        if let left = try? await session.room(toAccept) { try? await left.forget() }
        try await session.logout()
        await peer.logout()
    }

    @Test("New chats: directory search, a direct chat that is reused, a private room with an invitation (creates rooms and cleans up)",
          .enabled(if: env["HALO_DEV_PEER_USER"] != nil))
    func newChats() async throws {
        let server = env["HALO_DEV_SERVER"] ?? ""
        let peerName = env["HALO_DEV_PEER_USER"] ?? ""
        let peer = try UserID("@\(peerName):halo.localhost")
        let session = port()
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"), on: details)
        try await MatrixSyncPort(session: session).start()
        let chats = MatrixChatCreationPort(session: session)

        // The directory only lists users who share a room with the searcher (Synapse default); the peer does.
        let found = try await chats.searchUsers(peerName, limit: 10)
        #expect(found.contains { $0.id == peer }, "directory search didn't find the peer")
        #expect(try await chats.searchUsers("   ", limit: 10).isEmpty)

        let dm = try await chats.startDirectChat(with: peer)
        for _ in 0..<30 {
            if let known = try? await session.room(dm), await known.isDirect() { break }
            try await Task.sleep(for: .seconds(1))
        }
        var again = try await chats.startDirectChat(with: peer)
        for _ in 0..<30 where again != dm {  // m.direct arrives with a sync
            try await Task.sleep(for: .seconds(1))
            again = try await chats.startDirectChat(with: peer)
        }
        #expect(again == dm, "a second direct chat was created")

        let room = try await chats.createRoom(name: "New room fixture", invite: [peer])
        let rooms = MatrixRoomPort(session: session)
        var info: RoomDetails?
        for _ in 0..<30 where info?.name != "New room fixture" {
            try await Task.sleep(for: .seconds(1))
            info = try? await rooms.details(room)
        }
        #expect(info?.isEncrypted == true && info?.name == "New room fixture")
        for id in [dm, room] {
            try? await rooms.leave(id)
            if let left = try? await session.room(id) { try? await left.forget() }
        }
        try await session.logout()
    }

    @Test("Profiles: own display name round-trips (restored), another profile, ignore and unignore (restored)",
          .enabled(if: env["HALO_DEV_PEER_USER"] != nil))
    func profiles() async throws {
        let server = env["HALO_DEV_SERVER"] ?? ""
        let peerName = env["HALO_DEV_PEER_USER"] ?? ""
        let peer = try UserID("@\(peerName):halo.localhost")
        let session = port()
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"), on: details)
        try await MatrixSyncPort(session: session).start()
        let profiles = MatrixProfilePort(session: session)

        let original = try await profiles.ownDisplayName()
        let changed = "Contract \(UUID().uuidString.prefix(6))"
        try await profiles.setOwnDisplayName(changed)
        #expect(try await profiles.ownDisplayName() == changed)
        try await profiles.setOwnDisplayName(original)
        #expect(try await profiles.ownDisplayName() == original)

        // Avatar: only when the account has none, so a real picture is never replaced.
        if try await profiles.ownAvatar() == nil {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            try await profiles.setOwnAvatar(mimeType: "image/png", data: png)
            let ref = try await profiles.ownAvatar()
            #expect(ref != nil)
            if let ref { #expect(try await MatrixMediaPort(session: session).content(ref) == png) }
            try await profiles.removeOwnAvatar()
            #expect(try await profiles.ownAvatar() == nil)
        }

        let other = try await profiles.profile(of: peer)
        #expect(other.userID == peer)

        let before = try await profiles.ignoredUsers()
        try await profiles.ignore(peer)
        var ignored = try await profiles.ignoredUsers()
        for _ in 0..<30 where !ignored.contains(peer) {  // account data arrives with a sync
            try await Task.sleep(for: .seconds(1))
            ignored = try await profiles.ignoredUsers()
        }
        #expect(ignored.contains(peer))
        try await profiles.unignore(peer)
        for _ in 0..<30 where ignored.contains(peer) {
            try await Task.sleep(for: .seconds(1))
            ignored = try await profiles.ignoredUsers()
        }
        #expect(ignored == before)
        try await session.logout()
    }

    @Test("An enabled pack whose room the user has left is reported as unavailable, not as a failed load (creates a room and cleans up after itself)")
    func unavailablePack() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let client = try await session.signedInClient()
        let roomID = try await client.createRoom(request: CreateRoomParameters(name: "Unavailable pack fixture", isEncrypted: false, visibility: .private, preset: .privateChat))
        let ref = PackRef(room: try RoomID(roomID), stateKey: "gone")
        var room: Room?
        for _ in 0..<30 {
            if let known = try? await session.room(ref.room) { room = known; break }
            try await Task.sleep(for: .seconds(1))
        }
        let local = try #require(room)
        let pack = #"{"pack":{"display_name":"Gone","usage":["sticker"]},"images":{"wave":{"url":"mxc://halo.localhost/gone0000000000000000"}}}"#
        _ = try await local.sendStateEventRaw(eventType: "m.room.image_pack", stateKey: ref.stateKey, content: pack, requestConfigOverride: nil)
        let before = try await client.accountData(eventType: "m.image_pack.rooms")
        try await client.setAccountData(eventType: "m.image_pack.rooms", content: #"{"version":1,"rooms":{"\#(roomID)":{"gone":{}}}}"#)

        let packs = MatrixStickerPackPort(session: session)
        var readable = try await packs.packs(currentRoom: nil)
        for _ in 0..<30 where !readable.packs.contains(where: { $0.ref == ref }) {  // account data reaches the SDK store with a sync
            try await Task.sleep(for: .seconds(1))
            readable = try await packs.packs(currentRoom: nil)
        }
        #expect(readable.packs.contains { $0.ref == ref })
        // Leave and forget: the room is no longer readable (403/404) and the pack is reported, not counted as a failure.
        try await local.leave()
        try? await local.forget()
        var load = try await packs.packs(currentRoom: nil)
        for _ in 0..<15 where !load.unavailable.contains(ref) {
            try await Task.sleep(for: .seconds(1))
            load = try await packs.packs(currentRoom: nil)
        }
        #expect(load.unavailable.contains(ref) && !load.packs.contains { $0.ref == ref } && load.failedSources == 0)
        // Removing it takes it out of the enabled list: it is no longer reported (account data reaches the SDK store with a sync).
        try await packs.disable(ref)
        for _ in 0..<30 where load.unavailable.contains(ref) {
            try await Task.sleep(for: .seconds(1))
            load = try await packs.packs(currentRoom: nil)
        }
        #expect(!load.unavailable.contains(ref))
        try await packs.disable(ref)  // a second removal is harmless
        // Restore the account data (an empty listing if there was none), so no pack stays enabled.
        try? await client.setAccountData(eventType: "m.image_pack.rooms", content: before ?? "{}")
        try await session.logout()
    }

    @Test("The media preview setting round-trips through account data and is restored (changes the account's setting while it runs)")
    func mediaPreviewSetting() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let policy = MatrixMediaPreviewPolicyPort(session: session)
        let original = await policy.setting()
        func waitFor(_ expected: MediaPreviewSetting) async throws -> MediaPreviewSetting {
            var seen = await policy.setting()
            for _ in 0..<30 where seen != expected {  // account data reaches the SDK store with a sync
                try await Task.sleep(for: .seconds(1))
                seen = await policy.setting()
            }
            return seen
        }
        for target in MediaPreviewSetting.allCases where target != original {
            try await policy.setSetting(target)
            #expect(try await waitFor(target) == target)
        }
        // Resolution per room: "never" hides everywhere; "always" shows everywhere.
        let room = try RoomID(env["HALO_DEV_STICKER_ROOM"] ?? "!x:halo.localhost")
        try await policy.setSetting(.never)
        _ = try await waitFor(.never)
        #expect(await policy.previewsAllowed(in: room) == false)
        try await policy.setSetting(.always)
        _ = try await waitFor(.always)
        #expect(await policy.previewsAllowed(in: room) == true)
        try await policy.setSetting(original)
        #expect(try await waitFor(original) == original)
        try await session.logout()
    }

    @Test("Notification defaults per chat type and the mention rules round-trip through push rules and are restored (changes the account's defaults while it runs)")
    func notificationDefaults() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()  // the push rules arrive with the first sync
        try await Task.sleep(for: .seconds(4))
        let defaults = MatrixNotificationDefaultsPort(session: session)
        func waitFor(_ expected: RoomNotificationChoice, _ kind: NotificationDefaultKind) async throws -> RoomNotificationChoice {
            var seen = try await defaults.mode(for: kind)
            for _ in 0..<20 where seen != expected {  // the rule change reaches the SDK's ruleset with a sync
                try await Task.sleep(for: .seconds(1))
                seen = try await defaults.mode(for: kind)
            }
            return seen
        }
        for kind in NotificationDefaultKind.allCases {
            let original = try await defaults.mode(for: kind)
            let other: RoomNotificationChoice = original == .allMessages ? .mentionsAndKeywords : .allMessages
            try await defaults.setMode(other, for: kind)
            #expect(try await waitFor(other, kind) == other)
            try await defaults.setMode(original, for: kind)
            #expect(try await waitFor(original, kind) == original)
        }
        for kind in NotificationMentionKind.allCases {
            let original = try await defaults.isMentionEnabled(kind)
            try await defaults.setMention(kind, enabled: !original)
            var seen = try await defaults.isMentionEnabled(kind)
            for _ in 0..<20 where seen == original {
                try await Task.sleep(for: .seconds(1))
                seen = try await defaults.isMentionEnabled(kind)
            }
            #expect(seen == !original)
            try await defaults.setMention(kind, enabled: original)
            for _ in 0..<20 where seen != original {
                try await Task.sleep(for: .seconds(1))
                seen = try await defaults.isMentionEnabled(kind)
            }
            #expect(seen == original)
        }
        try await session.logout()
    }

    @Test("The sessions list contains this device, named as it signed in, first", .enabled(if: env["HALO_DEV_SERVER"] != nil))
    func devicesList() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract-devices"),
            on: details)
        let devices = try await MatrixDevicesPort(session: session).devices()
        #expect(devices.first?.isCurrent == true)
        #expect(devices.first?.displayName == "contract-devices")
        #expect(devices.filter(\.isCurrent).count == 1)
        try await session.logout()
    }

    @Test("Changing the password checks the current one, takes effect for new logins, and is restored (changes the peer account's password while it runs)", .enabled(if: env["HALO_DEV_SERVER"] != nil))
    func changePassword() async throws {
        let server = env["HALO_DEV_SERVER"] ?? ""
        let user = env["HALO_DEV_PEER_USER"] ?? ""
        let original = env["HALO_DEV_PEER_PASSWORD"] ?? ""
        let changed = original + "-changed-1"
        let session = port()
        let details = try await session.loginDetails(server: server)
        _ = try await session.loginPassword(PasswordCredentials(username: user, password: original, deviceDisplayName: "contract-password"), on: details)
        let passwords = MatrixAccountPasswordPort(session: session)
        #expect(await passwords.canChangePassword())
        do { try await passwords.changePassword(current: "definitely-wrong", new: changed); Issue.record("accepted a wrong password") } catch {
            #expect(error == .invalidInput("CURRENT_PASSWORD"))
        }
        try await passwords.changePassword(current: original, new: changed)
        // The session survives (other sessions stay signed in) and the new password logs in.
        let other = port()
        _ = try await other.loginPassword(PasswordCredentials(username: user, password: changed, deviceDisplayName: "contract-password"), on: details)
        try await passwords.changePassword(current: changed, new: original)
        try await other.logout()
        try await session.logout()
    }

    @Test("Bot allowlist syncs via one.mbm.halo.bot_allowlist account data and restores original", .enabled(if: env["HALO_DEV_SERVER"] != nil))
    func botAllowlist() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        try await MatrixSyncPort(session: session).start()
        let allowlist = MatrixBotAllowlistPort(session: session)
        let original = (try? await allowlist.load()) ?? BotAllowlist()
        let testBot = try UserID("@contract-bot:halo.localhost")
        let updated = BotAllowlist(bots: [testBot])
        try await allowlist.save(updated)
        var seen = try? await allowlist.load()
        for _ in 0..<30 where seen != updated {
            try await Task.sleep(for: .seconds(1))
            seen = try? await allowlist.load()
        }
        #expect(seen == updated)
        try await allowlist.save(original)
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

    /// MESSAGING FR-3 offline: messages sent while the server is unreachable fail honestly (recoverable), go out exactly once when it
    /// is back, by themselves (sync running) or through `retrySend` (sync stopped); an echo removed with `abortSend` never reaches the
    /// server. The dev Synapse is stopped and started by `scripts/contract-offline-test.sh`, which sets HALO_DEV_OFFLINE_DIR; without
    /// it the test is skipped.
    @Test("Offline send: failed echoes, delivery after reconnect, retrySend and abortSend (stops infra/dev; uses HALO_DEV_STICKER_ROOM)",
          .enabled(if: env["HALO_DEV_OFFLINE_DIR"] != nil && env["HALO_DEV_STICKER_ROOM"] != nil))
    func offlineSend() async throws {
        let control = ServerControl(directory: URL(fileURLWithPath: env["HALO_DEV_OFFLINE_DIR"] ?? ""))
        defer { control.resumeIfPaused() }  // never leave the server down, whatever failed
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
            on: details)
        let sync = MatrixSyncPort(session: session)
        try await sync.start()
        let room = try RoomID(env["HALO_DEV_STICKER_ROOM"] ?? "")
        var timeline: (any TimelineSession)?
        for _ in 0..<60 {
            if let opened = try? await MatrixTimelinePort(session: session).open(room: room) { timeline = opened; break }
            try await Task.sleep(for: .seconds(1))
        }
        let opened = try #require(timeline)
        let mirror = TimelineMirror(opened.items())
        let tag = UUID().uuidString.prefix(6)
        let automatic = "offline automatic \(tag)", aborted = "offline aborted \(tag)", retried = "offline retried \(tag)"
        // A stopped server fails a send within seconds; a paused one (`docker pause`) took ~90 s (30 s timeouts and retries).
        let failing = 120.0

        // 1. Offline: the first message fails (recoverable), the second waits behind it and is aborted.
        try await control.pause()
        try await opened.send(text: automatic, mentions: [])
        try await opened.send(text: aborted, mentions: [])
        let failedState: SendState = try await mirror.wait(seconds: failing, "\(automatic) failed") { mirror in
            guard let event = mirror.own(automatic), case .failed = event.sendState else { return nil }
            return event.sendState
        }
        #expect(failedState == .failed(recoverable: true))
        let abortedID = try await mirror.wait(seconds: 10, "\(aborted) echo") { $0.own(aborted)?.localID }
        try await opened.abortSend(localID: abortedID)
        _ = try await mirror.wait(seconds: 10, "\(aborted) removed") { $0.own(aborted) == nil ? true : nil }

        // 2. Back online with sync running: the failed message goes out without any user action.
        try await control.resume()
        // Against a stopped server the SDK's sync call ends with a generic error, which ends the loop with `.failed`; the app's
        // `SyncCoordinator` then restarts it. Do the same here (a no-op if the loop is still running).
        try await sync.start()
        _ = try await mirror.wait(seconds: 240, "\(automatic) sent") { $0.own(automatic)?.sendState == .sent ? true : nil }

        // 3. Offline again, then back and the user taps retry at once (before the next sync recovers the queue).
        try await control.pause()
        try await opened.send(text: retried, mentions: [])
        let retriedID: String = try await mirror.wait(seconds: failing, "\(retried) failed") { mirror in
            guard let event = mirror.own(retried), case .failed(recoverable: true) = event.sendState else { return nil }
            return event.localID
        }
        try await control.resume()
        try await opened.retrySend(localID: retriedID)
        _ = try await mirror.wait(seconds: 240, "\(retried) sent") { $0.own(retried)?.sendState == .sent ? true : nil }
        await #expect(throws: HaloError.notFound) { try await opened.abortSend(localID: abortedID) }  // gone for good

        // 4. The server's view (a plain HTTP login of its own): each delivered message exactly once, the aborted one never.
        let bodies = try await ServerMessages(server: env["HALO_DEV_SERVER"] ?? "", room: room)
            .bodies(user: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "")
        #expect(bodies.filter { $0 == automatic }.count == 1, "\(automatic): \(bodies.filter { $0 == automatic }.count) on the server")
        #expect(bodies.filter { $0 == retried }.count == 1, "\(retried): \(bodies.filter { $0 == retried }.count) on the server")
        #expect(!bodies.contains(aborted))
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
        // A caption becomes the message body (a client then shows it under the picture instead of the file name).
        let caption = "caption \(UUID().uuidString.prefix(6))"
        let captionStream = opened.items()  // a new subscription starts from a full snapshot; the first one's diffs were consumed above
        try await opened.sendImage(OutgoingImage(data: png, filename: "captioned-\(name)", mimeType: "image/png", width: 1, height: 1, caption: caption))
        let captioned: MediaAttachment? = try await within(seconds: 60) {
            var items: [HaloDomain.TimelineItem] = []
            for await diff in captionStream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, event.isOwn, event.eventID != nil, case .media(let attachment) = event.kind, attachment.body == caption { return attachment }
                }
            }
            return nil
        }
        #expect(captioned?.kind == .image)
        await #expect(throws: HaloError.invalidInput("NOT_AN_IMAGE")) {
            try await opened.sendImage(OutgoingImage(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain", width: nil, height: nil))
        }
        await opened.close()
        try await session.logout()
    }

    @Test("Sending a file, an audio clip and a video (uses HALO_DEV_STICKER_ROOM as a scratch room)", .enabled(if: env["HALO_DEV_STICKER_ROOM"] != nil))
    func sendFiles() async throws {
        let session = port()
        let details = try await session.loginDetails(server: env["HALO_DEV_SERVER"] ?? "")
        _ = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_DEV_USER"] ?? "", password: env["HALO_DEV_PASSWORD"] ?? "", deviceDisplayName: "contract"),
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
        let tag = UUID().uuidString.prefix(6)
        let sent: [(name: String, mime: String, kind: MediaKind)] = [
            ("doc-\(tag).txt", "text/plain", .file), ("clip-\(tag).m4a", "audio/mp4", .audio), ("movie-\(tag).mp4", "video/mp4", .video),
        ]
        for file in sent {
            try await opened.sendFile(OutgoingFile(data: Data("contract \(file.name)".utf8), filename: file.name, mimeType: file.mime))
        }
        let found: [String: MediaAttachment] = try await within(seconds: 90) {
            var items: [HaloDomain.TimelineItem] = []
            var seen: [String: MediaAttachment] = [:]
            for await diff in stream {
                try ListReducer.apply(diff, to: &items)
                for item in items {
                    if case .event(let event) = item.content, event.isOwn, event.eventID != nil, case .media(let attachment) = event.kind,
                       sent.contains(where: { $0.name == attachment.body }) { seen[attachment.body] = attachment }
                }
                if seen.count == sent.count { return seen }
            }
            return seen
        }
        for file in sent {
            let attachment = try #require(found[file.name], "\(file.name) did not arrive")
            #expect(attachment.kind == file.kind && attachment.mimeType == file.mime && attachment.size == "contract \(file.name)".utf8.count && attachment.source != nil)
        }
        // The bytes come back through the media port.
        let text = try #require(found[sent[0].name])
        let data = try await MatrixMediaPort(session: session).content(try #require(text.source))
        #expect(String(decoding: data, as: UTF8.self) == "contract \(sent[0].name)")
        await #expect(throws: HaloError.invalidInput("EMPTY_FILE")) {
            try await opened.sendFile(OutgoingFile(data: Data(), filename: "x.txt", mimeType: "text/plain"))
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
        // Leave no trace: unlist the pack (otherwise every run adds one enabled pack to the account), then leave and
        // forget the pack room; later tests expect the account to be in HALO_DEV_ROOMS rooms.
        let client = try await session.signedInClient()
        for type in ["m.image_pack.rooms", "one.mbm.halo.sticker_rooms"] {
            guard let json = try await client.accountData(eventType: type),
                  var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
            if var rooms = object["rooms"] as? [String: Any] { rooms[ref.room.rawValue] = nil; object["rooms"] = rooms }  // enabled packs
            else if let rooms = object["rooms"] as? [String] { object["rooms"] = rooms.filter { $0 != ref.room.rawValue } }  // hidden rooms
            try await client.setAccountData(eventType: type, content: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        let local = try await session.room(ref.room)
        try await local.leave()
        try? await local.forget()
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

        // Changing the key (Settings → Security → Change recovery key): the verified first device replaces it; the new key
        // unlocks a third device and the old one no longer does.
        let replaced = try await within(seconds: 90) { try await MatrixEncryptionPort(session: first).resetRecovery() }
        #expect(replaced != key)
        let third = port()
        _ = try await third.loginPassword(PasswordCredentials(username: user, password: password, deviceDisplayName: "e2ee-3"), on: details)
        try await MatrixSyncPort(session: third).start()
        let fresh = MatrixEncryptionPort(session: third)
        do {
            try await within(seconds: 90) { try await fresh.recover(recoveryKey: key) }
            Issue.record("the old recovery key still unlocks a new device")
        } catch {}
        try await within(seconds: 90) { try await EncryptionPortContract.verifyRecovery(fresh, recoveryKey: replaced) }
        try await first.logout()
        try await second.logout()
        try await third.logout()
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

/// Takes the dev Synapse down and up again for `offlineSend`. The simulator can't run docker, so the test writes `<step>.req` into
/// HALO_DEV_OFFLINE_DIR and `scripts/contract-offline-test.sh` answers with `<step>.ack` ("ok" or the error) once it is done.
private final class ServerControl: Sendable {
    private struct State { var step = 0; var paused = false }
    private let directory: URL
    private let state = Mutex(State())

    init(directory: URL) { self.directory = directory }

    func pause() async throws { try await request("pause", paused: true) }
    func resume() async throws { try await request("resume", paused: false) }

    /// For `defer`: asks for a resume without waiting (the script also resumes when it exits).
    func resumeIfPaused() {
        let step: Int? = state.withLock { state in
            guard state.paused else { return nil }
            state.step += 1
            state.paused = false
            return state.step
        }
        guard let step else { return }
        try? Data().write(to: directory.appendingPathComponent("resume-\(step).req"))
    }

    private func request(_ action: String, paused: Bool) async throws {
        let step = state.withLock { state in
            state.step += 1
            return state.step
        }
        let name = "\(action)-\(step)"
        try Data().write(to: directory.appendingPathComponent(name + ".req"))
        let ack = directory.appendingPathComponent(name + ".ack")
        for _ in 0..<600 {
            if let answer = try? String(contentsOf: ack, encoding: .utf8) {
                guard answer.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw ContractViolation("\(name): \(answer)") }
                state.withLock { $0.paused = paused }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ContractViolation("no answer to \(name) within 60 s; run this test through scripts/contract-offline-test.sh")
    }
}

/// The timeline kept up to date in the background, so a test can wait for several states of one stream in turn.
private final class TimelineMirror: Sendable {
    private let items = Mutex<[HaloDomain.TimelineItem]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<HaloDomain.TimelineDiff>) {
        let consumer = Task { [weak self] in
            for await diff in stream {
                guard let self else { return }
                self.items.withLock { items in
                    do { try ListReducer.apply(diff, to: &items) } catch { Issue.record("timeline diff didn't apply: \(error)") }
                }
            }
        }
        task.withLock { $0 = consumer }
    }

    deinit { task.withLock { $0?.cancel() } }

    /// The own text message with this body, if the timeline holds it.
    func own(_ body: String) -> HaloDomain.TimelineEvent? {
        items.withLock { items in
            for item in items.reversed() {
                if case .event(let event) = item.content, event.isOwn, case .text(let text, _) = event.kind, text == body { return event }
            }
            return nil
        }
    }

    /// Polls `probe` until it returns a value; fails after `seconds`.
    func wait<T: Sendable>(seconds: Double, _ what: String, _ probe: (TimelineMirror) -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let value = probe(self) { return value }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ContractViolation("timed out after \(seconds) s waiting for: \(what)")
    }
}

/// The latest message bodies of a room as the server has them, read with a plain HTTP login of its own (logged out again).
private struct ServerMessages {
    let server: String
    let room: RoomID

    func bodies(user: String, password: String) async throws -> [String] {
        let login = try await call("POST", "/login", body: [
            "type": "m.login.password", "identifier": ["type": "m.id.user", "user": user], "password": password,
            "initial_device_display_name": "offline check",
        ])
        let token = try #require(login["access_token"] as? String)
        let room = room.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? room.rawValue
        let page = try await call("GET", "/rooms/\(room)/messages?dir=b&limit=100", token: token)
        _ = try? await call("POST", "/logout", token: token, body: [:])
        let chunk = page["chunk"] as? [[String: Any]] ?? []
        return chunk.compactMap { event in
            guard event["type"] as? String == "m.room.message" else { return nil }
            return (event["content"] as? [String: Any])?["body"] as? String
        }
    }

    private func call(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try #require(URL(string: server + "/_matrix/client/v3" + path)))
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// A second account over plain HTTP that creates rooms and invites the contract account.
private final class PeerInviter: @unchecked Sendable {
    private let server: String
    private var token = ""
    init(server: String) { self.server = server }

    func login(_ user: String, _ password: String) async throws {
        let reply = try await call("POST", "/login", body: ["type": "m.login.password", "identifier": ["type": "m.id.user", "user": user], "password": password])
        token = try #require(reply["access_token"] as? String)
    }

    func createRoom(name: String, invite: String) async throws -> String {
        let reply = try await call("POST", "/createRoom", body: ["name": name, "preset": "private_chat", "invite": [invite]])
        return try #require(reply["room_id"] as? String)
    }

    func logout() async { _ = try? await call("POST", "/logout", body: [:]) }

    private func call(_ method: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try #require(URL(string: server + "/_matrix/client/v3" + path)))
        request.httpMethod = method
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
