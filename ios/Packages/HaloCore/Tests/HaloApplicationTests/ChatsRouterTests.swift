import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("ChatsRouter & PreferencesStore (M12, D85, TD-02)")
struct ChatsRouterTests {
    @Test("openRoom deduplicates consecutive pushes for the same room and updates focus when jumping to an event")
    func deduplicatesRoomsAndUpdatesFocus() throws {
        let roomA = try RoomID("!a:x.org")
        let roomB = try RoomID("!b:x.org")
        let ev1 = try EventID("$1")
        let ev2 = try EventID("$2")

        var router = ChatsRouter()
        router.openRoom(roomA)
        router.openRoom(roomA)
        #expect(router.path == [.room(roomA, focus: nil)])

        // Jumping to an event in the already-open room updates focus in place rather than pushing a duplicate.
        router.openRoom(roomA, focus: ev1)
        #expect(router.path == [.room(roomA, focus: ev1)])
        router.openRoom(roomA, focus: ev2)
        #expect(router.path == [.room(roomA, focus: ev2)])

        // Opening a different room pushes it.
        router.openRoom(roomB)
        #expect(router.path == [.room(roomA, focus: ev2), .room(roomB, focus: nil)])
    }

    @Test("push deduplicates Settings, Activity, StickerLibrary, and GlobalMediaGallery")
    func deduplicatesDestinations() {
        var router = ChatsRouter()
        router.push(.settings)
        router.push(.settings)
        #expect(router.path == [.settings])

        router.push(.stickerLibrary)
        router.push(.stickerLibrary)
        #expect(router.path == [.settings, .stickerLibrary])

        router.push(.activity)
        router.push(.globalMediaGallery)
        #expect(router.path == [.settings, .stickerLibrary, .activity, .globalMediaGallery])

        router.popToRoot()
        #expect(router.path.isEmpty)
    }

    @Test("State restoration round-trips through Data and prunes rooms no longer joined (NAVIGATION §4)")
    func stateRestorationAndPruning() throws {
        let joinedRoom = try RoomID("!joined:x.org")
        let leftRoom = try RoomID("!left:x.org")
        let rootEvent = try EventID("$root")

        var router = ChatsRouter()
        router.push(.settings)
        router.openRoom(leftRoom)
        router.openThread(room: leftRoom, rootEvent: rootEvent)
        router.openRoom(joinedRoom, focus: rootEvent)

        let data = try #require(router.encodePath())
        var restored = ChatsRouter()
        restored.restorePath(from: data)
        #expect(restored.path == router.path)

        restored.pruneInvalidRooms(joinedRoomIDs: [joinedRoom])
        #expect(restored.path == [.settings, .room(joinedRoom, focus: rootEvent)])

        // Corrupt data leaves existing path untouched.
        restored.restorePath(from: Data("not-json".utf8))
        #expect(restored.path == [.settings, .room(joinedRoom, focus: rootEvent)])
    }

    @Test("PreferencesStore reads, persists, and updates live through PreferencesPort (TD-02)")
    @MainActor
    func preferencesStoreRoundTrip() {
        let fake = FakePreferencesPort(initial: PreferencesSnapshot(privateReceipts: true, botSenders: ["@bot:x.org"]))
        let store = PreferencesStore(port: fake)

        #expect(store.privateReceipts == true)
        #expect(store.botSenders == ["@bot:x.org"])
        #expect(store.privacyBlur == true)

        store.botSenders = ["@bot:x.org", "@todo:x.org"]
        store.appearance = .dark
        store.privacyBlur = false

        let saved = fake.load()
        #expect(saved.botSenders == ["@bot:x.org", "@todo:x.org"])
        #expect(saved.appearance == .dark)
        #expect(saved.privacyBlur == false)
    }
}

@Suite("ChatsRouter on iPad (M16, D91)")
struct ChatsRouterSplitTests {
    private let roomA = try! RoomID("!a:x.org")
    private let roomB = try! RoomID("!b:x.org")

    @Test("opening another room replaces the detail instead of stacking, and a thread still stacks on its room")
    func roomsReplace() {
        var router = ChatsRouter(replacesDetail: true)
        router.openRoom(roomA)
        router.openRoom(roomB)
        #expect(router.path == [.room(roomB, focus: nil)])
        router.openThread(room: roomB, rootEvent: try! EventID("$t"))
        #expect(router.path.count == 2)
        router.openRoom(roomA)
        #expect(router.path == [.room(roomA, focus: nil)])
    }

    @Test("a top-level destination replaces a room; one opened from another destination stacks on it")
    func destinations() {
        var router = ChatsRouter(replacesDetail: true)
        router.openRoom(roomA)
        router.push(.settings)
        #expect(router.path == [.settings])
        router.push(.stickerLibrary)
        #expect(router.path == [.settings, .stickerLibrary])
        router.openRoom(roomB)
        #expect(router.path == [.room(roomB, focus: nil)])
    }

    @Test("the iPhone router still stacks")
    func phoneStacks() {
        var router = ChatsRouter()
        router.openRoom(roomA)
        router.openRoom(roomB)
        router.push(.settings)
        #expect(router.path.count == 3)
    }
}
