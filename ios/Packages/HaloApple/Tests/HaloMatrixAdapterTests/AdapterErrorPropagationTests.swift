import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloMatrixAdapter

@Suite("Adapter error propagation (audit S-6)")
struct AdapterErrorPropagationTests {
    private let room = try! RoomID("!room:x.org")
    private let alice = try! UserID("@alice:x.org")

    @Test("GalleryCollector surfaces reducer corruption as an error instead of silently returning missing media, and recovers on reset")
    func galleryCollectorPropagatesReducerError() throws {
        let collector = GalleryCollector(ownUserID: alice.rawValue, sleep: { _ in })
        let mediaItem = TimelineItem(
            id: TimelineItemID("m1"),
            content: .event(TimelineEvent(
                eventID: try EventID("$m1"),
                sender: alice,
                senderName: "Alice",
                timestamp: Date(timeIntervalSince1970: 100),
                isOwn: true,
                kind: .media(MediaAttachment(kind: .image, body: "pic.jpg", source: MediaRef(token: "mxc://x/1")))
            ))
        )

        // Out-of-bounds removal on an empty list corrupts the stream.
        collector.applyMapped([.remove(index: 5)])
        #expect(throws: HaloError.self) {
            _ = try collector.mediaItemsNewestFirst()
        }

        // A subsequent `.reset` cleanly restores the collector state.
        collector.applyMapped([.reset([mediaItem])])
        let items = try collector.mediaItemsNewestFirst()
        #expect(items.map(\.eventID) == [try EventID("$m1")])
    }

    @Test("HistoryMirror surfaces reducer corruption as an error instead of advancing the search anchor past dropped events, and recovers on reset")
    func historyMirrorPropagatesReducerError() throws {
        let mirror = HistoryMirror(room: room)
        let entry = SearchIndexEntry(
            room: room,
            event: try EventID("$s1"),
            sender: alice,
            senderName: "Alice",
            threadRoot: nil,
            timestamp: Date(timeIntervalSince1970: 200),
            content: SearchableContent(kind: .message, body: "indexed message")
        )

        mirror.applyMapped([.remove(index: 42)])
        #expect(throws: HaloError.self) {
            _ = try mirror.slice(reachedStart: true)
        }

        mirror.applyMapped([.reset([.message(entry)])])
        let slice = try mirror.slice(reachedStart: true)
        #expect(slice.entries == [entry])
        #expect(slice.reachedStart)
    }

    @Test("UnpinPolicy still attempts room unpin when roomInfo() read failed after personal-pin removal")
    func unpinPolicyFailsSafeWhenRoomInfoUnavailable() {
        #expect(UnpinPolicy.shouldUnpinRoom(isRoomPinned: nil, removedPersonal: true))
        #expect(UnpinPolicy.shouldUnpinRoom(isRoomPinned: true, removedPersonal: true))
        #expect(!UnpinPolicy.shouldUnpinRoom(isRoomPinned: false, removedPersonal: true))
        #expect(UnpinPolicy.shouldUnpinRoom(isRoomPinned: false, removedPersonal: false))
    }
}
