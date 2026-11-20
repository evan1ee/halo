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
        #expect(model.row(event(.media(MediaAttachment(kind: .file, body: "a.pdf", source: nil)))).text == "[File] a.pdf")
        let image = model.row(event(.media(MediaAttachment(kind: .image, body: "cat.png", source: MediaRef(token: "t"), width: 200, height: 100))))
        #expect(image.text == "cat.png" && image.image == .init(ref: MediaRef(token: "t"), aspectRatio: 2))
        #expect(model.row(event(.media(MediaAttachment(kind: .image, body: "x.png", source: nil)))).text == "[Image] x.png")
        #expect(model.row(event(.notice("fyi", isEdited: false))).style == .notice)
    }

    @Test("undecryptable, deleted and unsupported events are shown honestly, never hidden")
    func placeholders() throws {
        let model = try model()
        #expect(model.row(event(.undecryptable(.unknown))).text.hasPrefix("Unable to decrypt this message"))
        // Every reason has its own explanation, and none is empty.
        let reasons: [UTDReason] = [.unknown, .sentBeforeJoining, .keysNotShared, .senderVerificationProblem, .backupDisabled]
        #expect(Set(reasons.map(TimelineViewModel.text(for:))).count == reasons.count)
        #expect(TimelineViewModel.text(for: .backupDisabled).contains("recovery key"))
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

    @Test("unconfirmed own messages say so; sent ones carry no status")
    func sendStatus() throws {
        let model = try model()
        func own(_ state: SendState) -> TimelineItem {
            TimelineItem(id: TimelineItemID("o"), content: .event(TimelineEvent(
                eventID: nil, sender: nil, senderName: "Me", timestamp: Date(timeIntervalSince1970: 0), isOwn: true,
                kind: .text("hi", isEdited: false), sendState: state)))
        }
        #expect(model.row(own(.sent)).status == nil)
        #expect(model.row(own(.sending)).status == "Sending…")
        #expect(model.row(own(.failed(recoverable: true))).status?.contains("retry") == true)
        #expect(model.row(own(.failed(recoverable: false))).status == "Not sent")
    }

    @Test("a successful send clears the draft; a failed send keeps it and explains")
    func composer() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [event(.text("one", isEdited: false))])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }

        model.draft = "  "
        #expect(!model.canSend)
        model.draft = "hello"
        #expect(model.canSend)
        await model.send()
        #expect(model.draft.isEmpty && model.sendError == nil)
        #expect(port.sentTexts(in: room) == ["hello"])

        await model.stop()  // closed timeline: the send is refused, the text must survive
        model.draft = "kept"
        await model.send()
        #expect(model.draft == "kept" && model.sendError != nil)
    }

    @Test("reactions, edit and delete drive the timeline through the coordinator; edit mode round-trips the text")
    func interactions() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        func rows() -> [TimelineRow] { if case .live(let rows, _, _, _) = model.content { rows } else { [] } }
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }

        model.draft = "my message"
        await model.send()
        for _ in 0..<500_000 where rows().first?.eventID == nil { await Task.yield() }
        let sent = try #require(rows().first)
        #expect(sent.isOwn && sent.eventID != nil)

        await model.toggleReaction(on: sent, key: "👍")
        for _ in 0..<500_000 where rows().first?.reactions.isEmpty != false { await Task.yield() }
        #expect(rows().first?.reactions == [.init(key: "👍", count: 1, reactedByMe: true)])

        model.beginEdit(rows()[0])
        #expect(model.editing != nil && model.draft == "my message")
        model.draft = "changed"
        await model.send()
        #expect(model.editing == nil && model.draft.isEmpty)
        for _ in 0..<500_000 where rows().first?.text != "changed (edited)" { await Task.yield() }
        #expect(rows().first?.text == "changed (edited)")

        await model.delete(rows()[0])
        for _ in 0..<500_000 where rows().first?.text != "Message deleted" { await Task.yield() }
        #expect(rows().first?.text == "Message deleted")
    }

    @Test("a reply quotes the original, and cancelling or editing drops the reply target")
    func replies() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        func rows() -> [TimelineRow] { if case .live(let rows, _, _, _) = model.content { rows } else { [] } }
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }

        model.draft = "original"
        await model.send()
        for _ in 0..<500_000 where rows().first?.eventID == nil { await Task.yield() }
        let original = try #require(rows().first)

        model.beginReply(original)
        model.cancelReply()
        #expect(model.replyingTo == nil)
        model.beginReply(original)
        model.draft = "answer"
        await model.send()
        #expect(model.replyingTo == nil && model.draft.isEmpty)
        for _ in 0..<500_000 where rows().count < 2 || rows()[1].eventID == nil { await Task.yield() }
        #expect(rows()[1].text == "answer" && rows()[1].reply?.snippet == "original")

        // An unconfirmed row can't be replied to.
        model.beginReply(TimelineRow(id: "x", style: .ownMessage, sender: nil, text: "pending"))
        #expect(model.replyingTo == nil)
    }

    @Test("a text message with an HTML body gets styled text; a plain one doesn't; edits keep the suffix")
    func styledText() throws {
        let model = try model()
        func message(html: String?, edited: Bool) -> TimelineItem {
            TimelineItem(id: TimelineItemID("id"), content: .event(TimelineEvent(
                eventID: nil, sender: nil, senderName: "Alice", timestamp: Date(timeIntervalSince1970: 0), isOwn: false,
                kind: .text("**b**", isEdited: edited), formattedBody: html)))
        }
        #expect(model.row(message(html: nil, edited: false)).styled == nil)
        let styled = model.row(message(html: "<strong>b</strong>", edited: true)).styled
        #expect(styled.map { String($0.characters) } == "b (edited)")
    }

    @Test("the emoji picker reacts to its target, closes, and is unavailable for unconfirmed rows")
    func picker() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await model.start()
        func rows() -> [TimelineRow] { if case .live(let rows, _, _, _) = model.content { rows } else { [] } }
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }
        model.draft = "pick"
        await model.send()
        for _ in 0..<500_000 where rows().first?.eventID == nil { await Task.yield() }

        model.beginReactionPicker(TimelineRow(id: "x", style: .message, sender: nil, text: "pending"))
        #expect(model.reactionTarget == nil)
        model.beginReactionPicker(try #require(rows().first))
        #expect(model.reactionTarget != nil)
        await model.pickReaction("🎉")
        #expect(model.reactionTarget == nil)
        for _ in 0..<500_000 where rows().first?.reactions.isEmpty != false { await Task.yield() }
        #expect(rows().first?.reactions == [.init(key: "🎉", count: 1, reactedByMe: true)])
        #expect(Set(TimelineViewModel.pickerEmoji).count == TimelineViewModel.pickerEmoji.count)
        #expect(TimelineViewModel.quickReactions.allSatisfy(TimelineViewModel.pickerEmoji.contains))
    }

    @Test("typing text uses known names, falls back to the user ID, and collapses for many people")
    func typingText() throws {
        let alice = try UserID("@alice:x.org")
        let bob = try UserID("@bob:x.org")
        let carol = try UserID("@carol:x.org")
        let items = [event(.text("hi", isEdited: false))]  // sender @alice:x.org named "Alice"
        #expect(TimelineViewModel.typingText([], items: items) == nil)
        #expect(TimelineViewModel.typingText([alice], items: items) == "Alice is typing…")
        #expect(TimelineViewModel.typingText([alice, bob], items: items) == "Alice and @bob:x.org are typing…")
        #expect(TimelineViewModel.typingText([alice, bob, carol], items: items) == "Several people are typing…")
    }

    @Test("someone else's message can't be edited or deleted from the UI")
    func foreign() throws {
        let model = try model()
        let row = model.row(event(.text("theirs", isEdited: false)))
        model.beginEdit(row)
        #expect(model.editing == nil)
    }

    @Test("the newest visible confirmed event is reported as read once the app is active; nothing while inactive")
    func readReceipts() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: port)
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), receipts: receipts, room: room,
            dwell: .zero, sleep: { _ in }, locale: Locale(identifier: "en_US"), timeZone: .gmt)
        func item(_ n: Int) throws -> TimelineItem {
            TimelineItem(id: TimelineItemID("i\(n)"), content: .event(TimelineEvent(
                eventID: try EventID("$e\(n)"), sender: nil, senderName: "Bob", timestamp: Date(timeIntervalSince1970: Double(n)),
                isOwn: false, kind: .text("m\(n)", isEdited: false))))
        }
        let items = [try item(1), try item(2), try item(3)]
        model.apply(.live(.init(items: items, isPaginating: false, reachedStart: true, paginationError: nil)))
        let rows = items.map(model.row)

        model.setActive(false)
        model.rowVisibility(rows[0], isVisible: true)
        model.rowVisibility(rows[1], isVisible: true)
        for _ in 0..<2000 { await Task.yield() }
        #expect(port.receipts.isEmpty)

        model.setActive(true)
        for _ in 0..<200_000 where port.receipts.isEmpty { await Task.yield() }
        #expect(port.receipts.map(\.event.rawValue) == ["$e2"])

        // A row that scrolls out is not reported; a not-yet-confirmed row (no event id) never is.
        model.rowVisibility(rows[1], isVisible: false)
        model.rowVisibility(TimelineRow(id: "echo", style: .ownMessage, sender: nil, text: "x"), isVisible: true)
        for _ in 0..<2000 { await Task.yield() }
        #expect(port.receipts.count == 1)
    }

    @Test("opening the room clears m.marked_unread once the screen is visible, not while inactive")
    func clearsMarkedUnreadOnOpen() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: port)
        try await receipts.markRoomUnread(room)
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), receipts: receipts, room: room,
            dwell: .zero, sleep: { _ in }, locale: Locale(identifier: "en_US"), timeZone: .gmt)
        model.setActive(false)
        await model.start()
        for _ in 0..<2000 { await Task.yield() }
        #expect(port.unreadFlags[room] == true)
        model.setActive(true)
        for _ in 0..<200_000 where port.unreadFlags[room] == true { await Task.yield() }
        #expect(port.unreadFlags[room] == false)
        await model.stop()
    }

    @Test("a confirmed own message becomes the read position; someone else's, or one still sending, doesn't (FR-6)")
    func ownMessageIsRead() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: port)
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), receipts: receipts, room: room,
            dwell: .zero, sleep: { _ in }, locale: Locale(identifier: "en_US"), timeZone: .gmt)
        func item(_ n: Int, own: Bool, id: Bool = true) throws -> TimelineItem {
            TimelineItem(id: TimelineItemID("i\(n)"), content: .event(TimelineEvent(
                eventID: id ? try EventID("$e\(n)") : nil, sender: nil, senderName: "x", timestamp: Date(timeIntervalSince1970: Double(n)),
                isOwn: own, kind: .text("m\(n)", isEdited: false))))
        }
        func live(_ items: [TimelineItem]) { model.apply(.live(.init(items: items, isPaginating: false, reachedStart: true, paginationError: nil))) }
        live([try item(1, own: false), try item(2, own: true, id: false)])
        for _ in 0..<2000 { await Task.yield() }
        #expect(port.receipts.isEmpty)
        live([try item(1, own: false), try item(2, own: true)])
        for _ in 0..<200_000 where port.receipts.isEmpty { await Task.yield() }
        #expect(port.receipts.map(\.event.rawValue) == ["$e2"])
    }

    @Test("only a failed own echo can be retried or deleted from its row")
    func failedRows() async throws {
        let room = try RoomID("!r:x.org")
        func event(_ state: SendState, id: Bool = false, local: String? = "txn") throws -> TimelineEvent {
            TimelineEvent(
                eventID: id ? try EventID("$e") : nil, sender: nil, senderName: nil, timestamp: Date(timeIntervalSince1970: 1), isOwn: true,
                kind: .text("hi", isEdited: false), sendState: state, localID: local)
        }
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        func row(_ e: TimelineEvent) -> TimelineRow { model.row(TimelineItem(id: TimelineItemID("i"), content: .event(e))) }
        #expect(row(try event(.failed(recoverable: false))).failedLocalID == "txn")
        #expect(row(try event(.failed(recoverable: true))).failedLocalID == "txn")
        #expect(row(try event(.sending)).failedLocalID == nil)
        #expect(row(try event(.sent, id: true, local: nil)).failedLocalID == nil)
    }
}
