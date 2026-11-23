import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

@MainActor
@Suite("Composer: Article editor (D101)")
struct ArticleComposerTests {
    private func liveModel() async throws -> (TimelineViewModel, FakeTimelinePort, RoomID) {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }
        return (model, port, room)
    }

    @Test("an article is sent as one Markdown text message; the composer's draft is untouched and the article cleared")
    func sends() async throws {
        let (model, port, room) = try await liveModel()
        model.draft = "typing"
        model.articleDraft = "# Notes\n\n- **one**\n- two"
        #expect(await model.sendArticle())
        #expect(port.sentTexts(in: room) == ["# Notes\n\n- **one**\n- two"])
        #expect(model.articleDraft.isEmpty && model.draft == "typing")
        await model.stop()
    }

    @Test("an empty or too-long article isn't sent; a too-long one says why")
    func refuses() async throws {
        let (model, port, room) = try await liveModel()
        model.articleDraft = "  \n"
        #expect(await !model.sendArticle())
        #expect(model.sendError == nil)
        model.articleDraft = String(repeating: "a", count: ArticleMarkdown.maximumLength + 1)
        #expect(await !model.sendArticle())
        #expect(model.sendError?.contains("too long") == true)
        #expect(port.sentTexts(in: room).isEmpty)
        await model.stop()
    }

    @Test("a failed send keeps the article")
    func keepsOnFailure() async throws {
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")))
        model.articleDraft = "draft"
        #expect(await !model.sendArticle())
        #expect(model.articleDraft == "draft" && model.sendError == "The article couldn't be sent.")
    }

    @Test("the preview styles inline Markdown and keeps line breaks")
    func previewInline() {
        let styled = ArticlePreview.inline("**bold**\nnext")
        #expect(String(styled.characters) == "bold\nnext")
        #expect(styled.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}

@MainActor
@Suite("Timeline: rooms that open on room events only")
struct OpeningOnRoomEventsTests {
    @Test("a room whose loaded history is only a join loads earlier pages by itself until it finds a message, then lands")
    func loadsUntilMessage() async throws {
        let room = try RoomID("!r:x.org")
        let ann = try UserID("@ann:x.org")
        let join = TimelineItem(id: TimelineItemID("join"), content: .event(TimelineEvent(
            eventID: try EventID("$join"), sender: ann, senderName: "Ann", timestamp: Date(timeIntervalSince1970: 100), isOwn: false,
            kind: .membership(user: ann, displayName: "Ann", change: .joined))))
        let old = TimelineItem(id: TimelineItemID("old"), content: .event(TimelineEvent(
            eventID: try EventID("$old"), sender: ann, senderName: "Ann", timestamp: Date(timeIntervalSince1970: 10), isOwn: false,
            kind: .text("hello", isEdited: false))))
        let port = FakeTimelinePort()
        port.addRoom(room, items: [join], older: [[old]])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        for _ in 0..<500_000 where model.landingRow == nil { await Task.yield() }
        guard case .live(let rows, _, _, _) = model.content else { Issue.record("not live"); return }
        #expect(rows.contains { $0.text == "hello" } && model.landingRow == "join")
        await model.stop()
    }
}
