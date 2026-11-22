import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureRoomList

@MainActor
@Suite("ShareHandoffViewModel")
struct ShareHandoffViewModelTests {
    private let room = try! RoomID("!r:x.org")

    private func makeModel(onSent: @escaping @MainActor (RoomID) -> Void = { _ in }) -> (ShareHandoffViewModel, FakeShareInbox, FakeTimelinePort) {
        let inbox = FakeShareInbox()
        let timelines = FakeTimelinePort()
        timelines.addRoom(room)
        return (ShareHandoffViewModel(coordinator: ShareCoordinator(inbox: inbox, timelines: timelines), onSent: onSent), inbox, timelines)
    }

    @Test("refresh shows the oldest staged payload and nothing when the inbox is empty")
    func refresh() async {
        let (model, inbox, _) = makeModel()
        await model.refresh()
        #expect(model.current == nil)
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "hi")])
        inbox.stage(payload)
        await model.refresh()
        #expect(model.current == payload)
    }

    @Test("sending clears the payload and reports the room")
    func send() async {
        var opened: [RoomID] = []
        let (model, inbox, timelines) = makeModel { opened.append($0) }
        inbox.stage(SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "hi")]))
        await model.refresh()
        await model.send(to: room)
        #expect(model.current == nil)
        #expect(opened == [room])
        #expect(timelines.sentTexts(in: room) == ["hi"])
    }

    @Test("a failed send keeps the payload and shows a plain message; too large has its own")
    func failure() async {
        let (model, inbox, _) = makeModel()
        let file = SharedItem(kind: .file, filename: "x", mimeType: "a/b")
        inbox.stage(SharePayload(createdAt: Date(), items: [file]), files: [file.id: Data(count: OutgoingFile.maximumBytes + 1)])
        await model.refresh()
        await model.send(to: room)
        #expect(model.current != nil)
        #expect(model.errorMessage == "That file is too large to send.")
        await model.send(to: try! RoomID("!missing:x.org"))
        #expect(model.errorMessage == HaloErrorCopy.message(for: .notFound))
    }

    @Test("discard deletes it; closing the sheet keeps it for the next refresh")
    func discardAndClose() async {
        let (model, inbox, _) = makeModel()
        let payload = SharePayload(createdAt: Date(), items: [SharedItem(kind: .text, text: "x")])
        inbox.stage(payload)
        await model.refresh()
        model.sheetClosed()
        #expect(model.current == nil)
        await model.refresh()
        #expect(model.current == payload)
        await model.discard()
        #expect(inbox.discarded == [payload.id])
        #expect(model.current == nil)
    }
}
