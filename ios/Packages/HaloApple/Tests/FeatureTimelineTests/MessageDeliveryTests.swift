import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

/// One state model for every kind of own message (TIMELINE FR-6): sending → sent (check) → read (readers' avatars).
@MainActor
@Suite("Message delivery state")
struct MessageDeliveryTests {
    private func model() throws -> TimelineViewModel {
        TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    private func own(_ kind: TimelineEventKind, _ state: SendState, readers: Int = 0, confirmed: Bool = false) throws -> TimelineItem {
        let users = try (0..<readers).map { try UserID("@u\($0):x.org") }
        return TimelineItem(id: TimelineItemID("o"), content: .event(TimelineEvent(
            eventID: confirmed ? try EventID("$e") : nil, sender: try UserID("@me:x.org"), senderName: "Me", timestamp: Date(timeIntervalSince1970: 0),
            isOwn: true, kind: kind, sendState: state, localID: confirmed ? nil : "txn", readBy: users)))
    }

    private var kinds: [(String, TimelineEventKind)] {
        let source = MediaRef(token: "t")
        return [
            ("text", .text("hi", isEdited: false)),
            ("image", .media(MediaAttachment(kind: .image, body: "a.png", source: source, width: 4, height: 3))),
            ("video", .media(MediaAttachment(kind: .video, body: "a.mp4", source: source))),
            ("file", .media(MediaAttachment(kind: .file, body: "a.pdf", source: source))),
            ("audio", .media(MediaAttachment(kind: .audio, body: "a.m4a", source: source))),
            ("sticker", .sticker(body: "s", source: source)),
            ("location", .location(body: "here", geoURI: "geo:1,2")),
        ]
    }

    @Test("sending, sent and read look the same for text, photos, videos, files, audio, stickers and locations")
    func sameForEveryKind() throws {
        let model = try model()
        for (name, kind) in kinds {
            #expect(model.row(try own(kind, .sending)).delivery == .sending, "\(name) sending")
            #expect(model.row(try own(kind, .sending)).status == "Sending…", "\(name) sending text")
            #expect(model.row(try own(kind, .sent, confirmed: true)).delivery == .sent, "\(name) sent")
            #expect(model.row(try own(kind, .sent, confirmed: true)).status == nil, "\(name) sent has no status text")
            let read = model.row(try own(kind, .sent, readers: 2, confirmed: true))
            #expect(read.delivery == .read && read.readers.count == 2, "\(name) read")
            #expect(model.row(try own(kind, .failed(recoverable: false))).delivery == .failed(recoverable: false), "\(name) failed")
        }
    }

    @Test("a failed message of any kind can be retried or deleted (its local ID is kept)")
    func failedKeepsLocalID() throws {
        let model = try model()
        for (name, kind) in kinds {
            #expect(model.row(try own(kind, .failed(recoverable: false))).failedLocalID == "txn", "\(name)")
        }
        #expect(model.row(try own(kinds[0].1, .sending)).failedLocalID == nil)
    }

    @Test("receipts don't show before the server confirms, and other people's messages carry no state")
    func noReceiptsBeforeConfirmation() throws {
        let model = try model()
        let sending = model.row(try own(kinds[1].1, .sending, readers: 2))
        #expect(sending.delivery == .sending && sending.seenBy == 0 && sending.readers.isEmpty)
        let theirs = TimelineItem(id: TimelineItemID("t"), content: .event(TimelineEvent(
            eventID: nil, sender: try UserID("@alice:x.org"), senderName: "Alice", timestamp: Date(timeIntervalSince1970: 0),
            isOwn: false, kind: .media(MediaAttachment(kind: .image, body: "a.png", source: MediaRef(token: "t"))), sendState: .sent)))
        #expect(model.row(theirs).delivery == nil)
    }

    @Test("the mapping is exhaustive over the send states")
    func deliveryMapping() {
        #expect(TimelineRow.Delivery(sendState: .sending, readCount: 3) == .sending)
        #expect(TimelineRow.Delivery(sendState: .sent, readCount: 0) == .sent)
        #expect(TimelineRow.Delivery(sendState: .sent, readCount: 1) == .read)
        #expect(TimelineRow.Delivery(sendState: .failed(recoverable: true), readCount: 0) == .failed(recoverable: true))
    }
}
