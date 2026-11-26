import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

@MainActor
@Suite("Timeline thumbnail memory: a sent photo is never loaded again")
struct TimelineThumbnailMemoryTests {
    private let local = MediaRef(token: "mxc://send-queue.localhost/txn")
    private let remote = MediaRef(token: "mxc://server/abc")

    private func photoRow(id: String, ref: MediaRef) -> TimelineRow {
        TimelineRow(id: id, style: .ownMessage, sender: "Me", text: "a.png", image: .init(ref: ref, aspectRatio: 1.5))
    }

    @Test("the picture of the local echo becomes the entry for the confirmed reference")
    func adoptKeepsThePicture() {
        let memory = TimelineThumbnailMemory()
        memory.store(Data([1, 2, 3]), for: local)
        #expect(memory.data(for: remote) == nil)
        memory.adopt(local, as: remote)
        #expect(memory.data(for: remote) == Data([1, 2, 3]), "a view for the confirmed reference paints it at once")
        #expect(memory.data(for: local) == Data([1, 2, 3]))
    }

    @Test("adopting never replaces a picture that was loaded for the new reference, nor invents one")
    func adoptIsConservative() {
        let memory = TimelineThumbnailMemory()
        memory.adopt(local, as: remote)
        #expect(memory.data(for: remote) == nil)
        memory.store(Data([9]), for: remote)
        memory.store(Data([1]), for: local)
        memory.adopt(local, as: remote)
        #expect(memory.data(for: remote) == Data([9]))
    }

    @Test("a row whose photo reference changes is reported once; new and unchanged rows are not")
    func changedReferences() {
        var known: [String: MediaRef] = [:]
        #expect(TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "33", ref: local)], known: &known).isEmpty)
        #expect(TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "33", ref: local)], known: &known).isEmpty)
        let changes = TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "33", ref: remote), photoRow(id: "40", ref: remote)], known: &known)
        #expect(changes.count == 1 && changes[0].old == local && changes[0].new == remote)
        #expect(TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "33", ref: remote)], known: &known).isEmpty)
    }

    @Test("memory is bounded; the least recently used picture goes first")
    func eviction() {
        let memory = TimelineThumbnailMemory(byteLimit: 10)
        let a = MediaRef(token: "a"), b = MediaRef(token: "b"), c = MediaRef(token: "c")
        memory.store(Data(repeating: 1, count: 4), for: a)
        memory.store(Data(repeating: 2, count: 4), for: b)
        _ = memory.data(for: a)  // a is now newer than b
        memory.store(Data(repeating: 3, count: 4), for: c)
        #expect(memory.data(for: b) == nil && memory.data(for: a) != nil && memory.data(for: c) != nil)
        memory.store(Data(repeating: 4, count: 11), for: MediaRef(token: "huge"))
        #expect(memory.data(for: MediaRef(token: "huge")) == nil, "more than the whole budget isn't kept")
    }

    @Test("the room opened again (a new view model) paints the pictures shown before at once: the app's timelines share one memory")
    func reopenedRoomPaintsAtOnce() async throws {
        let shared = TimelineThumbnailMemory()
        let room = try RoomID("!r:x.org")
        func model() -> TimelineViewModel {
            TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), thumbnails: shared)
        }
        let photo = TimelineRow.Image(ref: remote, aspectRatio: 1.5)
        let first = model()
        first.thumbnailMemory.store(Data([5]), for: remote)  // what `thumbnail(for:)` keeps after a load
        let reopened = model()
        #expect(reopened.cachedThumbnail(for: photo) == Data([5]), "the row's first frame has the picture, no placeholder")
        shared.removeAll()  // memory warning or sign-out
        #expect(reopened.cachedThumbnail(for: photo) == nil)
        #expect(TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room)).thumbnailMemory !== shared)
    }

    @Test("a view model hands out what it loaded, and carries a photo over to its confirmed reference")
    func viewModelCarriesTheEcho() async throws {
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        let echo = TimelineRow.Image(ref: local, aspectRatio: 1.5), confirmed = TimelineRow.Image(ref: remote, aspectRatio: 1.5)
        model.thumbnailMemory.store(Data([7]), for: local)
        #expect(model.cachedThumbnail(for: echo) == Data([7]) && model.cachedThumbnail(for: confirmed) == nil)
        for change in TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "1", ref: local)], known: &model.knownPhotoRefs) { _ = change }
        for change in TimelineThumbnailMemory.changedReferences(rows: [photoRow(id: "1", ref: remote)], known: &model.knownPhotoRefs) {
            model.thumbnailMemory.adopt(change.old, as: change.new)
        }
        #expect(model.cachedThumbnail(for: confirmed) == Data([7]))
        // With no media loader the model answers from memory and doesn't invent anything for an unknown reference.
        #expect(await model.thumbnail(for: confirmed) == Data([7]))
        #expect(await model.thumbnail(for: .init(ref: MediaRef(token: "other"), aspectRatio: nil)) == nil)
    }
}
