import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

@MainActor
@Suite("TimelineViewModel")
struct TimelineViewModelTests {
    private func model() throws -> TimelineViewModel {
        TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    private func event(_ kind: TimelineEventKind, own: Bool = false, name: String? = "Alice") -> TimelineItem {
        TimelineItem(
            id: TimelineItemID("id"),
            content: .event(TimelineEvent(
                eventID: nil, sender: try? UserID("@alice:x.org"), senderName: name, timestamp: Date(timeIntervalSince1970: 0),
                isOwn: own, kind: kind)))
    }

    @Test("text, notice, emote and media rows carry the sender and a readable label")
    func messages() throws {
        let model = try model()
        #expect(model.row(event(.text("hi", isEdited: false))) == TimelineRow(id: "id", style: .message, sender: "Alice", text: "hi"))
        #expect(model.row(event(.text("hi", isEdited: true), own: true)).text == "hi (edited)")
        #expect(model.row(event(.text("hi", isEdited: false), own: true)).style == .ownMessage)
        #expect(model.row(event(.emote("waves", isEdited: false))).text == "Alice waves")
        #expect(model.row(event(.media(.image, body: "cat.png"))).text == "[Image] cat.png")
        #expect(model.row(event(.notice("fyi", isEdited: false))).style == .notice)
    }

    @Test("undecryptable, deleted and unsupported events are shown honestly, never hidden")
    func placeholders() throws {
        let model = try model()
        #expect(model.row(event(.undecryptable)).text == "Unable to decrypt this message")
        #expect(model.row(event(.redacted)).text == "Message deleted")
        #expect(model.row(event(.unsupported)).text == "Unsupported event")
    }

    @Test("a sender without a display name falls back to the user ID, not an empty label")
    func senderFallback() throws {
        #expect(try model().row(event(.text("x", isEdited: false), name: nil)).sender == "@alice:x.org")
    }

    @Test("membership and date rows")
    func stateAndDates() throws {
        let model = try model()
        #expect(model.row(event(.membership(user: nil, displayName: "Bob", change: .joined))).text == "Bob joined")
        let divider = TimelineItem(id: TimelineItemID("d"), content: .virtual(.dateDivider(Date(timeIntervalSince1970: 0))))
        #expect(model.row(divider).text == "Jan 1, 1970")
    }

    @Test("statuses map to opening, live and failed content")
    func statuses() throws {
        let model = try model()
        model.apply(.opening)
        #expect(model.content == .opening)
        model.apply(.failed(.notFound))
        #expect(model.content == .failed("This room isn't available."))
        model.apply(.live(.init(items: [event(.redacted)], isPaginating: false, reachedStart: true, paginationError: nil)))
        guard case .live(let rows, _, let canLoadEarlier, _) = model.content else { Issue.record("not live"); return }
        #expect(rows.count == 1 && !canLoadEarlier)
    }

    @Test("consecutive room-setting rows collapse into one; other rows are kept")
    func collapses() throws {
        let model = try model()
        let items = [event(.otherState), event(.otherState), event(.text("hi", isEdited: false)), event(.otherState)]
        let rows = TimelineViewModel.collapsingStateRuns(items.map(model.row), items: items)
        #expect(rows.map(\.text) == ["The room was updated", "hi", "The room was updated"])
    }
}
