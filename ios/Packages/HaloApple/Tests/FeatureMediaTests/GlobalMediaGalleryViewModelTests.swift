import FeatureMedia
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

private actor StubMultiRoomGalleryPort: RoomPort {
    var galleries: [RoomID: Result<[RoomMediaItem], HaloError>] = [:]

    func set(_ result: Result<[RoomMediaItem], HaloError>, for room: RoomID) {
        galleries[room] = result
    }

    func details(_ room: RoomID) async throws(HaloError) -> RoomDetails { throw HaloError.notFound }
    func members(_ room: RoomID, limit: Int) async throws(HaloError) -> [RoomMemberInfo] { [] }
    func setNotificationMode(_ mode: RoomNotificationChoice, in room: RoomID) async throws(HaloError) {}
    func setDetails(name: String, topic: String, in room: RoomID) async throws(HaloError) {}
    func setAvatar(mimeType: String, data: Data, in room: RoomID) async throws(HaloError) {}
    func removeAvatar(in room: RoomID) async throws(HaloError) {}
    func invite(_ users: [UserID], to room: RoomID) async throws(HaloError) {}
    func acceptInvite(_ room: RoomID) async throws(HaloError) {}
    func invitePreview(_ room: RoomID) async throws(HaloError) -> RoomInvitePreview { throw HaloError.notFound }
    func declineInvite(_ room: RoomID) async throws(HaloError) {}
    func setFavourite(_ favourite: Bool, in room: RoomID) async throws(HaloError) {}
    func leave(_ room: RoomID) async throws(HaloError) {}

    func mediaGallery(in room: RoomID, limit: Int) async throws(HaloError) -> [RoomMediaItem] {
        guard let result = galleries[room] else { return [] }
        switch result {
        case .success(let items): return Array(items.prefix(limit))
        case .failure(let error): throw error
        }
    }

    func openMediaGallery(in room: RoomID) async throws(HaloError) -> any RoomMediaGallerySession {
        guard let result = galleries[room] else { return StubGallerySession(items: []) }
        switch result {
        case .success(let items): return StubGallerySession(items: items)
        case .failure(let error): throw error
        }
    }
}

private actor StubGallerySession: RoomMediaGallerySession {
    private let items: [RoomMediaItem]
    private var offset = 0

    init(items: [RoomMediaItem]) { self.items = items }

    func nextPage(limit: Int) async throws(HaloError) -> MediaGalleryPage {
        guard offset < items.count, limit > 0 else { return MediaGalleryPage(items: [], hasMore: false) }
        let end = min(items.count, offset + limit)
        let slice = Array(items[offset..<end])
        offset = end
        return MediaGalleryPage(items: slice, hasMore: offset < items.count)
    }

    func close() async {}
}

private actor StubMediaPort: MediaPort {
    var downloads: [MediaRef: Data] = [:]
    var contentCalls = 0
    var fileCalls = 0

    func set(_ data: Data, for ref: MediaRef) { downloads[ref] = data }

    func content(_ ref: MediaRef) async throws(HaloError) -> Data {
        contentCalls += 1
        guard let data = downloads[ref] else { throw HaloError.notFound }
        return data
    }

    func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data {
        guard let data = downloads[ref] else { throw HaloError.notFound }
        return data
    }

    func file(_ ref: MediaRef, name: String, mimeType: String?, in directory: URL) async throws(HaloError) -> URL {
        fileCalls += 1
        guard let data = downloads[ref] else { throw HaloError.notFound }
        let url = directory.appendingPathComponent(Self.safeFileName(name))
        do { try data.write(to: url, options: .atomic) } catch { throw .storage(.unavailable) }
        return url
    }
}

@MainActor
struct GlobalMediaGalleryViewModelTests {
    private static func makeCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        makeCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func aggregatesFiltersGroupsAndExportsAcrossJoinedRooms() async throws {
        let roomA = try RoomID("!roomA:example.org")
        let roomB = try RoomID("!roomB:example.org")
        let inviteRoom = try RoomID("!invite:example.org")

        let listPort = FakeRoomListPort(rooms: [
            RoomSummary(id: roomA, name: "Design", isDirect: false, isEncrypted: true, membership: .joined),
            RoomSummary(id: roomB, name: "Family", isDirect: false, isEncrypted: true, membership: .joined),
            RoomSummary(id: inviteRoom, name: "Pending Invite", isDirect: false, isEncrypted: true, membership: .invited),
        ])
        let coordinator = RoomListCoordinator(port: listPort)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { break }
        }

        let photoRef = MediaRef(token: "mxc://example.org/photo1")
        let videoRef = MediaRef(token: "mxc://example.org/video1")
        let fileRef = MediaRef(token: "mxc://example.org/doc1")

        let novPhoto = RoomMediaItem(
            eventID: try EventID("$e1"),
            senderName: "Alice",
            timestamp: Self.date(2026, 11, 20),
            attachment: MediaAttachment(kind: .image, body: "sunset.jpg", source: photoRef, size: 1200)
        )
        let octVideo = RoomMediaItem(
            eventID: try EventID("$e2"),
            senderName: "Bob",
            timestamp: Self.date(2026, 10, 5),
            attachment: MediaAttachment(kind: .video, body: "clip.mp4", source: videoRef, size: 5000)
        )
        let novFile = RoomMediaItem(
            eventID: try EventID("$e3"),
            senderName: "Cara",
            timestamp: Self.date(2026, 11, 15),
            attachment: MediaAttachment(kind: .file, body: "spec.pdf", source: fileRef, size: 2400)
        )
        let invitePhoto = RoomMediaItem(
            eventID: try EventID("$e4"),
            senderName: "Mallory",
            timestamp: Self.date(2026, 11, 21),
            attachment: MediaAttachment(kind: .image, body: "secret.jpg", source: photoRef)
        )

        let roomPort = StubMultiRoomGalleryPort()
        await roomPort.set(.success([octVideo, novPhoto]), for: roomA)
        await roomPort.set(.success([novFile]), for: roomB)
        await roomPort.set(.success([invitePhoto]), for: inviteRoom)

        let mediaPort = StubMediaPort()
        await mediaPort.set(Data("jpeg-bytes".utf8), for: photoRef)
        let loader = MediaLoader(port: mediaPort)

        let model = GlobalMediaGalleryViewModel(
            rooms: coordinator,
            roomPort: roomPort,
            media: loader,
            calendar: Self.makeCalendar()
        )
        await model.load()

        // Invited room is excluded; joined rooms sorted newest first.
        #expect(model.items.map(\.item.eventID.rawValue) == ["$e1", "$e3", "$e2"])
        #expect(model.error == nil)
        #expect(model.availableRooms.map(\.name) == ["Design", "Family"])

        // Month grouping: November 2026 (2 items) before October 2026 (1 item).
        #expect(model.sections.map(\.id) == ["2026-11", "2026-10"])
        #expect(model.sections[0].items.count == 2)
        #expect(model.sections[1].items.count == 1)

        // Media-type filters.
        model.filter = .photos
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e1"])
        model.filter = .videos
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e2"])
        model.filter = .files
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e3"])

        // Room filter.
        model.filter = .all
        model.selectedRoomID = roomB
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e3"])

        // Search filter matches filename, sender, and room name case-insensitively.
        model.selectedRoomID = nil
        model.searchText = "SUNSET"
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e1"])
        model.searchText = "family"
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e3"])
        model.searchText = "bob"
        #expect(model.filteredItems.map(\.item.eventID.rawValue) == ["$e2"])
        model.searchText = ""

        // Full viewer file and export both stream via MediaPort.file (not content).
        let viewerFile = try #require(await model.fullImageFile(model.items[0]))
        #expect(try Data(contentsOf: viewerFile) == Data("jpeg-bytes".utf8))
        try? FileManager.default.removeItem(at: viewerFile.deletingLastPathComponent())

        let exported = await model.exportMediaFile(model.items[0])
        #expect(exported != nil)
        if let exported {
            #expect(exported.lastPathComponent == "sunset.jpg")
            #expect(try Data(contentsOf: exported) == Data("jpeg-bytes".utf8))
            try? FileManager.default.removeItem(at: exported.deletingLastPathComponent())
        }
        let fileCalls = await mediaPort.fileCalls
        let contentCalls = await mediaPort.contentCalls
        #expect(fileCalls == 2 && contentCalls == 0)
    }

    @Test func paginatesAcrossRoomPagesAndRoomBatches() async throws {
        let roomA = try RoomID("!pageA:example.org")
        let roomB = try RoomID("!pageB:example.org")
        let listPort = FakeRoomListPort(rooms: [
            RoomSummary(id: roomA, name: "Alpha", isDirect: false, isEncrypted: true, membership: .joined),
            RoomSummary(id: roomB, name: "Beta", isDirect: false, isEncrypted: true, membership: .joined),
        ])
        let coordinator = RoomListCoordinator(port: listPort)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { break }
        }

        let a1 = RoomMediaItem(eventID: try EventID("$a1"), senderName: "Ann", timestamp: Self.date(2026, 11, 20), attachment: MediaAttachment(kind: .image, body: "a1.jpg", source: nil))
        let a2 = RoomMediaItem(eventID: try EventID("$a2"), senderName: "Ann", timestamp: Self.date(2026, 11, 10), attachment: MediaAttachment(kind: .image, body: "a2.jpg", source: nil))
        let b1 = RoomMediaItem(eventID: try EventID("$b1"), senderName: "Bob", timestamp: Self.date(2026, 11, 15), attachment: MediaAttachment(kind: .image, body: "b1.jpg", source: nil))

        let roomPort = StubMultiRoomGalleryPort()
        await roomPort.set(.success([a1, a2]), for: roomA)
        await roomPort.set(.success([b1]), for: roomB)

        let model = GlobalMediaGalleryViewModel(rooms: coordinator, roomPort: roomPort, calendar: Self.makeCalendar())
        await model.load(perRoomLimit: 1, maxRooms: 1)
        #expect(model.items.map(\.item.eventID.rawValue) == ["$a1"])
        #expect(model.hasMore)

        await model.loadMore()
        #expect(model.items.map(\.item.eventID.rawValue) == ["$a1", "$b1", "$a2"])
        #expect(!model.hasMore)
        await model.closeSessions()
    }

    @Test func handlesPartialAndTotalRoomFailures() async throws {
        let roomOK = try RoomID("!ok:example.org")
        let roomFail = try RoomID("!fail:example.org")

        let listPort = FakeRoomListPort(rooms: [
            RoomSummary(id: roomOK, name: "OK", isDirect: false, isEncrypted: true, membership: .joined),
            RoomSummary(id: roomFail, name: "Broken", isDirect: false, isEncrypted: true, membership: .joined),
        ])
        let coordinator = RoomListCoordinator(port: listPort)
        await coordinator.start()
        for await status in await coordinator.statuses() {
            if case .loaded = status { break }
        }

        let roomPort = StubMultiRoomGalleryPort()
        let photo = RoomMediaItem(
            eventID: try EventID("$p1"),
            senderName: "Alice",
            timestamp: Self.date(2026, 11, 22),
            attachment: MediaAttachment(kind: .image, body: "pic.png", source: nil)
        )
        await roomPort.set(.success([photo]), for: roomOK)
        await roomPort.set(.failure(HaloError.network(retryable: true)), for: roomFail)

        let model = GlobalMediaGalleryViewModel(rooms: coordinator, roomPort: roomPort, calendar: Self.makeCalendar())
        await model.load()
        // Partial failure keeps items from healthy rooms and doesn't show an error banner.
        #expect(model.items.count == 1)
        #expect(model.error == nil)

        // Total failure surfaces a user-facing error.
        await roomPort.set(.failure(HaloError.network(retryable: true)), for: roomOK)
        await model.load()
        #expect(model.items.isEmpty)
        #expect(model.error == "No internet connection.")
    }
}
