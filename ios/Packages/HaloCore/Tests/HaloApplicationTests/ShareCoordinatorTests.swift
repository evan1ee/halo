import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("ShareCoordinator")
struct ShareCoordinatorTests {
    private let room = try! RoomID("!r:x.org")

    private func setUp() -> (ShareCoordinator, FakeShareInbox, FakeTimelinePort) {
        let inbox = FakeShareInbox()
        let timelines = FakeTimelinePort()
        timelines.addRoom(room)
        return (ShareCoordinator(inbox: inbox, timelines: timelines), inbox, timelines)
    }

    @Test("text, link, photo and file items are sent in order and the payload is discarded")
    func deliversEverything() async throws {
        let (coordinator, inbox, timelines) = setUp()
        let link = SharedItem(kind: .url, text: "https://example.org")
        let photo = SharedItem(kind: .image, filename: "a.jpg", mimeType: "image/jpeg", byteCount: 3, width: 30, height: 20)
        let file = SharedItem(kind: .file, filename: "b.pdf", mimeType: "application/pdf", byteCount: 2)
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "hi"), link, photo, file])
        inbox.stage(payload, files: [photo.id: Data([1, 2, 3]), file.id: Data([4, 5])])

        try await coordinator.deliver(payload, to: room)

        #expect(timelines.sentTexts(in: room) == ["hi", "https://example.org"])
        #expect(timelines.sentImages(in: room).map(\.filename) == ["a.jpg"])
        #expect(timelines.sentImages(in: room).first.map { [$0.width, $0.height] } == [30, 20])
        #expect(timelines.sentFiles(in: room).map(\.mimeType) == ["application/pdf"])
        #expect(inbox.discarded == [payload.id])
        #expect(await coordinator.pending().isEmpty)
    }

    @Test("a failed item keeps the payload and a retry skips what was already sent")
    func retrySkipsSent() async throws {
        let (coordinator, inbox, timelines) = setUp()
        let photo = SharedItem(kind: .image, filename: "a.jpg", mimeType: "image/jpeg", byteCount: 1)
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "first"), photo])
        inbox.stage(payload, files: [photo.id: Data([1])])
        timelines.failNextImage(with: .network(retryable: true), in: room)

        await #expect(throws: HaloError.network(retryable: true)) { try await coordinator.deliver(payload, to: room) }
        #expect(inbox.discarded.isEmpty)
        #expect(await coordinator.pending() == [payload])

        try await coordinator.deliver(payload, to: room)
        #expect(timelines.sentTexts(in: room) == ["first"])
        #expect(timelines.sentImages(in: room).count == 1)
        #expect(inbox.discarded == [payload.id])
    }

    @Test("an oversized file is refused with a reason code and nothing is discarded")
    func oversized() async {
        let (coordinator, inbox, _) = setUp()
        let file = SharedItem(kind: .file, filename: "big.bin", mimeType: "application/octet-stream")
        let payload = SharePayload(createdAt: Date(), items: [file])
        inbox.stage(payload, files: [file.id: Data(count: OutgoingFile.maximumBytes + 1)])
        await #expect(throws: HaloError.invalidInput("SHARE_TOO_LARGE")) { try await coordinator.deliver(payload, to: room) }
        #expect(inbox.discarded.isEmpty)
    }

    @Test("dismiss discards without sending")
    func dismiss() async {
        let (coordinator, inbox, timelines) = setUp()
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "x")])
        inbox.stage(payload)
        await coordinator.dismiss(payload)
        #expect(inbox.discarded == [payload.id])
        #expect(timelines.sentTexts(in: room).isEmpty)
    }

    @Test("payloads expire after seven days")
    func expiry() {
        let created = Date(timeIntervalSince1970: 0)
        let payload = SharePayload(createdAt: created, items: [])
        #expect(!payload.isExpired(at: created.addingTimeInterval(SharePayload.lifetime - 1)))
        #expect(payload.isExpired(at: created.addingTimeInterval(SharePayload.lifetime + 1)))
    }

    @Test("asking for confirmation waits for the server's echo and reports it")
    func confirmedDelivery() async throws {
        let (coordinator, inbox, timelines) = setUp()
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "hi")])
        inbox.stage(payload)
        let result = try await coordinator.deliver(payload, to: room, confirmingFor: .seconds(5))
        #expect(result == .confirmed)
        #expect(timelines.sentTexts(in: room) == ["hi"])
        #expect(inbox.discarded == [payload.id])
    }

    @Test("a send the server hasn't confirmed in time is reported as queued, not lost")
    func queuedDelivery() async throws {
        let (coordinator, inbox, _) = setUp()
        let photo = SharedItem(kind: .image, filename: "a.jpg", mimeType: "image/jpeg")
        let payload = SharePayload(createdAt: Date(), items: [photo])
        inbox.stage(payload, files: [photo.id: Data([1])])
        let result = try await coordinator.deliver(payload, to: room, confirmingFor: .milliseconds(100))
        #expect(result == .queued)
        #expect(inbox.discarded == [payload.id])
    }
}
