import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

private struct NoKlipy: KlipyPort {
    func trending(_ kind: KlipyKind, page: Int) async throws(HaloError) -> KlipyPage { KlipyPage(items: [], page: 1, hasNext: false) }
    func search(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage { KlipyPage(items: [], page: 1, hasNext: false) }
    func registerShare(_ item: KlipyItem, query: String?) async throws(HaloError) {}
    func media(_ url: URL) async throws(HaloError) -> Data { Data("GIF89a".utf8) }
}

@MainActor
@Suite("Composer: KLIPY and emoji panel (D97, D98)")
struct ComposerKlipyTests {
    private let gifURL = "https://static.klipy.com/ii/abc/md.gif"

    private func item(_ url: String) -> KlipyItem {
        let rendition = KlipyRendition(url: url, width: 2, height: 1, size: 3)
        return KlipyItem(slug: "hello", kind: .gifs, title: "Hello", preview: rendition, shared: rendition)
    }

    private func liveModel() async throws -> (TimelineViewModel, FakeTimelinePort, RoomID) {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }
        return (model, port, room)
    }

    @Test("a KLIPY item is sent as a message holding exactly its KLIPY URL; the draft is untouched")
    func sendsURL() async throws {
        let (model, port, room) = try await liveModel()
        model.draft = "typing"
        try await model.sendKlipy(item(gifURL))
        #expect(port.sentTexts(in: room) == [gifURL])
        #expect(model.draft == "typing")
        await model.stop()
    }

    @Test("anything that isn't a KLIPY media URL is refused")
    func refusesOtherURLs() async throws {
        let (model, port, room) = try await liveModel()
        await #expect(throws: HaloError.invalidInput("NOT_KLIPY_MEDIA")) { try await model.sendKlipy(item("https://example.com/x.gif")) }
        #expect(port.sentTexts(in: room).isEmpty)
        await model.stop()
    }

    @Test("a message that is only a KLIPY link renders as media; text around it keeps it a link")
    func rowDetection() {
        #expect(TimelineRow(id: "1", style: .message, sender: "a", text: gifURL).klipyURL?.absoluteString == gifURL)
        #expect(TimelineRow(id: "2", style: .ownMessage, sender: nil, text: "look \(gifURL)").klipyURL == nil)
        #expect(TimelineRow(id: "3", style: .notice, sender: "bot", text: gifURL).klipyURL == nil)
    }

    @Test("KLIPY links play inline only with KLIPY configured and media previews allowed")
    func gating() throws {
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")))
        #expect(!model.showsKlipyMedia)
        model.klipy = KlipyCatalog(port: NoKlipy())
        #expect(model.showsKlipyMedia)
        model.previewsHidden = true
        #expect(!model.showsKlipyMedia)
    }

    @Test("the emoji panel's delete key removes one whole emoji, flags and families included")
    func deleteBackward() throws {
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")))
        model.draft = "hi 🇯🇵👨‍👩‍👧"
        model.deleteBackward()
        #expect(model.draft == "hi 🇯🇵")
        model.deleteBackward()
        #expect(model.draft == "hi ")
        model.draft = ""
        model.deleteBackward()
        #expect(model.draft.isEmpty)
    }
}
