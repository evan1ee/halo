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
        let source = TimelineRow.Source(sender: "@alice:x.org", eventID: nil, body: "hi", formattedBody: nil)
        #expect(model.row(event(.text("hi", isEdited: false))) == TimelineRow(id: "id", style: .message, sender: "Alice", text: "hi", source: source))
        #expect(model.row(event(.text("hi", isEdited: true), own: true)).text == "hi (edited)")
        #expect(model.row(event(.text("hi", isEdited: false), own: true)).style == .ownMessage)
        #expect(model.row(event(.emote("waves", isEdited: false))).text == "Alice waves")
        #expect(model.row(event(.media(MediaAttachment(kind: .file, body: "a.pdf", source: nil)))).text == "[File] a.pdf")
        let image = model.row(event(.media(MediaAttachment(kind: .image, body: "cat.png", source: MediaRef(token: "t"), width: 200, height: 100))))
        #expect(image.text == "cat.png" && image.image == .init(ref: MediaRef(token: "t"), aspectRatio: 2))
        #expect(model.row(event(.media(MediaAttachment(kind: .image, body: "x.png", source: nil)))).text == "[Image] x.png")
        #expect(model.row(event(.notice("fyi", isEdited: false))).style == .notice)
    }

    @Test("a message from an allowlisted bot becomes a card when a parser recognises it; anyone else's stays text")
    func botCards() throws {
        let model = try model()
        let html = "Added Task <b>#7</b> for Ann: <i>\"Pay rent\"</i>"
        func item(sender: String, html: String?) -> TimelineItem {
            TimelineItem(id: TimelineItemID("id"), content: .event(TimelineEvent(
                eventID: nil, sender: try? UserID(sender), senderName: "Bot", timestamp: Date(timeIntervalSince1970: 0), isOwn: false,
                kind: .text("Added Task #7", isEdited: false), formattedBody: html)))
        }
        #expect(model.row(item(sender: "@bot:x.org", html: html)).card == nil)  // not on the allowlist
        model.botSenders = ["@bot:x.org"]
        #expect(model.row(item(sender: "@bot:x.org", html: html)).card == .taskAdded(id: "7", owner: "Ann", title: "Pay rent"))
        #expect(model.row(item(sender: "@other:x.org", html: html)).card == nil)
        #expect(model.row(item(sender: "@bot:x.org", html: "<b>hello</b>")).card == nil)  // no parser matches: plain formatted text
        #expect(model.row(item(sender: "@bot:x.org", html: nil)).card == nil)
    }

    @Test("ticking a bot list row sends one 👍 to the task's creating message, waits, completes on the bot's list, and times out otherwise")
    func tickingBotTasks() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        let bot = "@bot:x.org"
        func item(_ id: String, _ html: String) throws -> TimelineItem {
            TimelineItem(id: TimelineItemID(id), content: .event(TimelineEvent(
                eventID: try EventID("$\(id)"), sender: try UserID(bot), senderName: "Bot", timestamp: Date(timeIntervalSince1970: 0), isOwn: false,
                kind: .text("x", isEdited: false), formattedBody: html)))
        }
        let list = "📋 <b>T:</b><br/>• [<b>#1</b>] Milk<br/>• [<b>#2</b>] Rent<br/>"
        port.addRoom(room, items: [try item("a", "Added Task <b>#1</b> for Ann: <i>\"Milk\"</i>"), try item("l", list)])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        model.botSenders = [bot]
        model.botTimeout = .milliseconds(50)
        await model.start()
        for _ in 0..<500_000 { if case .live = model.content { break }; await Task.yield() }

        #expect(model.botRowState(bot: bot, id: "1") == .open)
        #expect(model.botRowState(bot: bot, id: "2") == .unavailable)  // no creating message seen: read-only
        await model.tickBotTask(bot: bot, id: "2")
        #expect(model.botRowState(bot: bot, id: "2") == .unavailable)

        await model.tickBotTask(bot: bot, id: "1")
        #expect(model.botRowState(bot: bot, id: "1") == .pending)
        await model.tickBotTask(bot: bot, id: "1")  // ignored while pending: no second 👍 (that would toggle it off)
        try await Task.sleep(for: .milliseconds(300))  // the 50 ms timeout passes
        #expect(model.botRowState(bot: bot, id: "1") == .noResponse)

        await model.tickBotTask(bot: bot, id: "1")  // again after the timeout: the 👍 is already there, none is sent
        #expect(model.botRowState(bot: bot, id: "1") == .pending)

        let done = "📋 <b>T:</b><br/>• [<b>#1</b>] <del>Milk</del> ✅<br/>• [<b>#2</b>] Rent<br/>"
        try port.emit(.pushBack(try item("l2", done)), in: room)
        for _ in 0..<500_000 where model.botRowState(bot: bot, id: "1") != .completed { await Task.yield() }
        #expect(model.botRowState(bot: bot, id: "1") == .completed)
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

    @Test("the unsent text is kept per room, restored on return, and survives an edit")
    func drafts() async throws {
        let room = try RoomID("!r:x.org")
        let store = FakeDrafts()
        let drafts = DraftCoordinator(store: store)
        func make() -> TimelineViewModel {
            let port = FakeTimelinePort()
            port.addRoom(room)
            return TimelineViewModel(
                coordinator: TimelineCoordinator(port: port, room: room), room: room, drafts: drafts, locale: Locale(identifier: "en_US"), timeZone: .gmt)
        }
        let first = make()
        first.draft = "not sent yet"
        for _ in 0..<200_000 where store.stored[room] == nil { await Task.yield() }
        #expect(store.stored[room] == "not sent yet")

        let second = make()  // the screen is opened again
        await second.start()
        #expect(second.draft == "not sent yet")
        await second.stop()

        let target = TimelineRow(id: "x", style: .ownMessage, sender: nil, text: "old text", eventID: try EventID("$e"), isOwn: true)
        second.beginEdit(target)
        #expect(second.draft == "old text")
        second.cancelEdit()
        #expect(second.draft == "not sent yet")
        for _ in 0..<2000 { await Task.yield() }
        #expect(store.stored[room] == "not sent yet")  // the edit text never replaced the draft
    }

    @Test("typing @ offers matching members; picking one inserts the name and the send carries the mention")
    func mentions() async throws {
        let room = try RoomID("!r:x.org")
        let alice = RoomMember(user: try UserID("@alice:x.org"), displayName: "Alice")
        let bob = RoomMember(user: try UserID("@bob:x.org"), displayName: nil)
        let port = FakeTimelinePort()
        port.addRoom(room)
        port.setMembers([alice, bob], in: room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        await model.start()
        for _ in 0..<200_000 { if case .live = model.content { break }; await Task.yield() }

        model.draft = "hello a@b"  // not at a word start
        #expect(model.mentionQuery == nil)
        model.draft = "hello @al"
        #expect(model.mentionQuery == "al")
        for _ in 0..<200_000 where model.members.isEmpty { await Task.yield() }
        #expect(model.mentionSuggestions == [alice])
        model.draft = "hello @"
        #expect(model.mentionSuggestions == [alice, bob])

        model.draft = "hello @al"
        model.pickMention(alice)
        #expect(model.draft == "hello @Alice ")
        #expect(model.mentionQuery == nil)
        model.draft += "welcome"
        await model.send()
        #expect(port.sentMentions(in: room) == [[alice.user]])
        #expect(model.draft.isEmpty)
        await model.stop()
    }

    @Test("a picked mention whose text was deleted before sending isn't sent")
    func deletedMention() async throws {
        let room = try RoomID("!r:x.org")
        let alice = RoomMember(user: try UserID("@alice:x.org"), displayName: "Alice")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        await model.start()
        for _ in 0..<200_000 { if case .live = model.content { break }; await Task.yield() }
        model.draft = "@"
        model.pickMention(alice)
        model.draft = "never mind"
        await model.send()
        #expect(port.sentMentions(in: room) == [[]])
        await model.stop()
    }

    @Test("an incoming sticker is an image row without a bubble; one without an image stays a labelled placeholder")
    func stickerRows() throws {
        let room = try RoomID("!r:x.org")
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        func row(_ source: MediaRef?) -> TimelineRow {
            model.row(TimelineItem(id: TimelineItemID("s"), content: .event(TimelineEvent(
                eventID: nil, sender: nil, senderName: "Bob", timestamp: Date(timeIntervalSince1970: 1), isOwn: false, kind: .sticker(body: "wave", source: source)))))
        }
        let withImage = row(MediaRef(token: "t"))
        #expect(withImage.isSticker && withImage.image?.ref == MediaRef(token: "t") && withImage.text == "wave")
        let without = row(nil)
        #expect(!without.isSticker && without.text == "[Sticker] wave")
    }

    @Test("a picked photo is prepared and sent; failures say what went wrong; without a preparer there is no photo button")
    func photos() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), images: StubPreparer(), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        #expect(model.canSendImages)
        await model.start()
        for _ in 0..<200_000 { if case .live = model.content { break }; await Task.yield() }

        await model.sendImage(data: Data("png".utf8), filename: "a.png")
        #expect(port.sentImages(in: room).map(\.filename) == ["a.png"] && model.sendError == nil && !model.isSendingImage)
        await model.sendImage(data: Data("text".utf8), filename: "a.txt")
        #expect(model.sendError == "That file isn't a picture." && port.sentImages(in: room).count == 1)
        port.failNextImage(with: .network(retryable: true), in: room)
        await model.sendImage(data: Data("png".utf8), filename: "b.png")
        #expect(model.sendError == "Can't reach the server. The picture wasn't sent.")
        await model.stop()

        let plain = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        #expect(!plain.canSendImages)
    }

    @Test("a picked photo waits in the composer; the typed text becomes its caption; removing or a failure keeps the right things")
    func photoCaption() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), images: StubPreparer(), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        await model.start()
        for _ in 0..<200_000 { if case .live = model.content { break }; await Task.yield() }

        #expect(!model.canSend)
        await model.attachPhoto(data: Data("png".utf8), filename: "a.png")
        #expect(model.pendingPhoto?.filename == "a.png" && model.canSend)  // a photo alone can be sent
        #expect(port.sentImages(in: room).isEmpty)  // nothing is sent by picking
        model.removePendingPhoto()
        #expect(model.pendingPhoto == nil && !model.canSend)

        await model.attachPhoto(data: Data("png".utf8), filename: "b.png")
        model.draft = "  Sunset at the pier  "
        port.failNextImage(with: .network(retryable: true), in: room)
        await model.send()
        #expect(model.sendError == "Can't reach the server. The picture wasn't sent.")
        #expect(model.pendingPhoto != nil && model.draft == "  Sunset at the pier  ")  // nothing typed or picked is lost
        await model.send()
        #expect(port.sentImages(in: room).map(\.caption) == ["Sunset at the pier"] && model.pendingPhoto == nil && model.draft.isEmpty)

        await model.attachPhoto(data: Data("png".utf8), filename: "c.png")
        await model.send()  // no text: no caption
        #expect(port.sentImages(in: room).last?.caption == nil)
        await model.attachPhoto(data: Data("text".utf8), filename: "a.txt")
        #expect(model.sendError == "That file isn't a picture." && model.pendingPhoto == nil)
        await model.stop()
    }

    private func timed(_ id: String, _ seconds: Double, own: Bool = false, kind: TimelineEventKind = .text("m", isEdited: false)) -> TimelineItem {
        TimelineItem(
            id: TimelineItemID(id),
            content: .event(TimelineEvent(
                eventID: nil, sender: try? UserID("@alice:x.org"), senderName: "Alice", timestamp: Date(timeIntervalSince1970: seconds),
                isOwn: own, kind: kind)))
    }

    @Test("landing: the first message from someone else after the read position; none when everything is read or the position is unknown")
    func firstUnread() {
        let items = [timed("a", 10), timed("b", 20, own: true), timed("c", 30), timed("d", 40)]
        let read = Date(timeIntervalSince1970: 20)
        #expect(TimelineViewModel.firstUnreadItemID(items, readThrough: read) == "c")
        #expect(TimelineViewModel.firstUnreadItemID(items, readThrough: Date(timeIntervalSince1970: 40)) == nil)
        #expect(TimelineViewModel.firstUnreadItemID(items, readThrough: nil) == nil)
        // Own messages and state events never count as the unread landing point.
        #expect(TimelineViewModel.firstUnreadItemID([timed("x", 50, own: true)], readThrough: read) == nil)
        #expect(TimelineViewModel.firstUnreadItemID([timed("y", 50, kind: .redacted)], readThrough: read) == nil)
        // Everything loaded is unread: land on the oldest message loaded.
        #expect(TimelineViewModel.firstUnreadItemID(items, readThrough: Date(timeIntervalSince1970: 0)) == "a")
    }

    @Test("with everything read, or no known position, the timeline lands on the newest row at the bottom")
    func landsAtBottom() {
        for readThrough in [Date(timeIntervalSince1970: 100), nil] {
            let vm = TimelineViewModel(
                coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try! RoomID("!r:x.org")),
                locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
            vm.readThroughAtOpen = readThrough
            vm.apply(.live(TimelineCoordinator.Snapshot(items: [timed("a", 10), timed("c", 30)], isPaginating: false, reachedStart: true, paginationError: nil)))
            #expect(vm.landingRow == "c" && !vm.landingIsUnread)
        }
    }

    @Test("the timeline lands once, on the first unread message, and not again on later updates")
    func landsOnce() throws {
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        vm.readThroughAtOpen = Date(timeIntervalSince1970: 20)
        func snapshot(_ items: [TimelineItem]) -> TimelineCoordinator.Status {
            .live(TimelineCoordinator.Snapshot(items: items, isPaginating: false, reachedStart: true, paginationError: nil))
        }
        vm.apply(snapshot([]))
        #expect(vm.landingRow == nil)  // nothing loaded yet: wait for the first items
        vm.apply(snapshot([timed("a", 10), timed("c", 30)]))
        #expect(vm.landingRow == "c" && vm.landingIsUnread)
        vm.landingShown()
        vm.apply(snapshot([timed("a", 10), timed("c", 30), timed("d", 40)]))
        #expect(vm.landingRow == nil)
    }

    @Test("the first unread message stays marked for the whole visit, and nothing is marked when all is read or the position is unknown (FR-4)")
    func unreadMarker() throws {
        func make(_ readThrough: Date?) throws -> TimelineViewModel {
            let vm = TimelineViewModel(
                coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
                locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
            vm.readThroughAtOpen = readThrough
            return vm
        }
        func snapshot(_ items: [TimelineItem]) -> TimelineCoordinator.Status {
            .live(TimelineCoordinator.Snapshot(items: items, isPaginating: false, reachedStart: true, paginationError: nil))
        }
        let vm = try make(Date(timeIntervalSince1970: 20))
        #expect(vm.unreadMarkerID == nil)
        vm.apply(snapshot([timed("a", 10), timed("c", 30), timed("d", 40)]))
        #expect(vm.unreadMarkerID == "c")
        vm.landingShown()
        vm.apply(snapshot([timed("a", 10), timed("c", 30), timed("d", 40), timed("e", 50)]))
        #expect(vm.unreadMarkerID == "c")  // later messages don't move it
        for readThrough in [Date(timeIntervalSince1970: 100), nil] {
            let other = try make(readThrough)
            other.apply(snapshot([timed("a", 10), timed("c", 30)]))
            #expect(other.unreadMarkerID == nil)
        }
    }

    @Test("file, audio and video attachments become tiles with what is known about them; a sender's file name can't leave the temp folder")
    func fileTiles() async throws {
        let vm = try model()
        let pdf = vm.row(event(.media(MediaAttachment(kind: .file, body: "plan.pdf", source: MediaRef(token: "f"), mimeType: "application/pdf", size: 1_200_000))))
        #expect(pdf.file?.name == "plan.pdf" && pdf.file?.detail.hasPrefix("PDF · ") == true && pdf.file?.detail.contains("MB") == true)
        #expect(!pdf.showsText && pdf.text == "[File] plan.pdf")
        let voice = vm.row(event(.media(MediaAttachment(kind: .audio, body: "voice.m4a", source: MediaRef(token: "a"), duration: 42.4))))
        #expect(voice.file?.detail == "0:42")
        let video = vm.row(event(.media(MediaAttachment(kind: .video, body: "clip.mp4", source: MediaRef(token: "v"), size: 3_000_000, duration: 75))))
        #expect(video.file?.detail.hasPrefix("1:15 · ") == true)
        let noSource = vm.row(event(.media(MediaAttachment(kind: .file, body: "gone.bin", source: nil))))
        #expect(noSource.file == nil && noSource.text == "[File] gone.bin" && noSource.showsText)
        #expect(vm.row(event(.media(MediaAttachment(kind: .file, body: "README", source: MediaRef(token: "r"), mimeType: "text/plain")))).file?.detail == "PLAIN")
        // A video's own still picture rides along; other kinds ignore one, and a video without one has none.
        let still = vm.row(event(.media(MediaAttachment(kind: .video, body: "clip.mp4", source: MediaRef(token: "v"), width: 320, height: 240, thumbnail: MediaRef(token: "t")))))
        #expect(still.file?.thumbnail?.ref == MediaRef(token: "t") && still.file?.thumbnail?.aspectRatio == 320.0 / 240.0)
        #expect(video.file?.thumbnail == nil)
        #expect(vm.row(event(.media(MediaAttachment(kind: .file, body: "a.bin", source: MediaRef(token: "x"), thumbnail: MediaRef(token: "t"))))).file?.thumbnail == nil)
    }

    @Test("opening a file downloads it into a temporary folder, shows it, and deleting it again on close; big files are refused")
    func openingFiles() async throws {
        let port = FakeMediaPort()
        let ref = MediaRef(token: "doc")
        port.add(ref, data: Data("hello".utf8))
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")), media: MediaLoader(port: port),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        func row(_ name: String, size: Int? = nil) -> TimelineRow {
            vm.row(event(.media(MediaAttachment(kind: .file, body: name, source: ref, size: size))))
        }
        await vm.openFile(row("../../evil.txt"))
        let url = try #require(vm.openedFile?.url)
        #expect(url.lastPathComponent == "evil.txt" && url.path.contains("halo-open-"))
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        vm.closeFile()
        #expect(vm.openedFile == nil && !FileManager.default.fileExists(atPath: url.path))
        await vm.openFile(row("big.bin", size: TimelineViewModel.openSizeLimit + 1))
        #expect(vm.openedFile == nil && vm.openFileError?.contains("too large") == true)
    }

    @Test("a picked file is sent as it is; too large or empty files and a failing send give honest messages")
    func sendingFiles() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), room: room,
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
        await vm.start()
        for _ in 0..<200_000 { if case .live = vm.content { break }; await Task.yield() }
        await vm.sendFile(data: Data("hello".utf8), filename: "plan.pdf", mimeType: "application/pdf")
        #expect(port.sentFiles(in: room) == [OutgoingFile(data: Data("hello".utf8), filename: "plan.pdf", mimeType: "application/pdf")])
        #expect(vm.sendError == nil && !vm.isSendingFile)
        await vm.sendFile(data: Data(), filename: "empty.txt", mimeType: "text/plain")
        #expect(vm.sendError == "That file is empty.")
        await vm.sendFile(data: Data("x".utf8), filename: "a/b.txt", mimeType: "text/plain")
        #expect(vm.sendError == "That file can't be sent.")
        port.failNextFile(in: room, with: .network(retryable: true))
        await vm.sendFile(data: Data("x".utf8), filename: "n.txt", mimeType: "text/plain")
        #expect(vm.sendError == "Can't reach the server. The file wasn't sent.")
        #expect(port.sentFiles(in: room).count == 1)
        #expect(OutgoingFile(data: Data(), filename: "a", mimeType: "audio/mp4").kind == .audio)
        #expect(OutgoingFile(data: Data(), filename: "a", mimeType: "video/mp4").kind == .video)
        #expect(OutgoingFile(data: Data(), filename: "a", mimeType: "application/zip").kind == .file)
    }
}

private struct StubPreparer: ImagePreparing {
    func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
        guard data == Data("png".utf8) else { throw .invalidInput("NOT_AN_IMAGE") }
        return OutgoingImage(data: data, filename: filename, mimeType: "image/png", width: 2, height: 1)
    }

    @Test("an image whose body is only its file name shows no text bubble; a caption, a sticker and plain text behave as before")
    func captionVisibility() {
        let image = TimelineRow.Image(ref: MediaRef(token: "t"), aspectRatio: 1)
        func row(_ text: String, image: TimelineRow.Image? = image, sticker: Bool = false) -> TimelineRow {
            TimelineRow(id: "x", style: .ownMessage, sender: nil, text: text, image: image, isSticker: sticker)
        }
        #expect(!row("photo.jpg").showsText && !row("IMG_0042.HEIC").showsText && !row("blue.png").showsText)
        #expect(row("Look at these flowers").showsText && row("see you at 5.30 pm").showsText && row("v1.2").showsText)
        #expect(!row("Waving", sticker: true).showsText)
        #expect(row("photo.jpg", image: nil).showsText)  // plain text that merely looks like a file name stays
    }

}

@MainActor
@Suite("Media preview policy")
struct MediaPreviewPolicyTests {
    private func make(allowed: Bool?) throws -> TimelineViewModel {
        TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            previewsAllowed: allowed.map { value in { @Sendable in value } },
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }
    private let image = TimelineRow.Image(ref: MediaRef(token: "m1"), aspectRatio: nil)

    @Test("photos are shown unless the setting hides them; a tap shows one photo and only that one (FR-7)")
    func hidesUntilTapped() async throws {
        let off = try make(allowed: false)
        await off.start()
        #expect(off.previewsHidden && !off.showsPreview(of: image))
        off.revealPreview(of: image)
        #expect(off.showsPreview(of: image))
        #expect(!off.showsPreview(of: .init(ref: MediaRef(token: "m2"), aspectRatio: nil)))
        for allowed in [true, nil] as [Bool?] {
            let on = try make(allowed: allowed)
            await on.start()
            #expect(!on.previewsHidden && on.showsPreview(of: image))
        }
    }
}
