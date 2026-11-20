import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One displayed row. Text is prepared here so the view only lays it out.
public struct TimelineRow: Equatable, Identifiable, Sendable {
    public enum Style: Equatable, Sendable { case message, ownMessage, notice, emote, placeholder, state, divider, marker }
    public let id: String
    public let style: Style
    public let sender: String?
    public let text: String
    /// An image to show above the text (the filename or caption), loaded through the view model.
    public let image: Image?
    /// "Sending…" or "Not sent" for an own message that the server hasn't confirmed; `nil` once it is sent.
    public let status: String?
    /// Set for confirmed events only: reactions, edits and deletes need it.
    public let eventID: EventID?
    public let isOwn: Bool
    public let reactions: [Chip]
    /// The quoted message, shown above the text of a reply.
    public let reply: Reply?
    /// Styled text for a message that came with an HTML body; the view shows `text` otherwise.
    public let styled: AttributedString?
    /// The local ID of an own message whose sending failed; the user can retry or delete it.
    public let failedLocalID: String?
    /// A sticker: its image is shown without a bubble or caption (`text` is the accessibility label).
    public let isSticker: Bool

    public struct Reply: Equatable, Sendable {
        public let sender: String?
        /// `nil` when the original isn't available; the view then says so.
        public let snippet: String?
    }

    public struct Chip: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let count: Int
        public let reactedByMe: Bool
    }

    public struct Image: Equatable, Sendable {
        public let ref: MediaRef
        /// Width / height, when the sender gave dimensions; the view falls back to 4:3.
        public let aspectRatio: Double?
    }

    init(
        id: String, style: Style, sender: String?, text: String, image: Image? = nil, status: String? = nil,
        eventID: EventID? = nil, isOwn: Bool = false, reactions: [Chip] = [], reply: Reply? = nil, styled: AttributedString? = nil,
        failedLocalID: String? = nil, isSticker: Bool = false
    ) {
        self.failedLocalID = failedLocalID
        self.isSticker = isSticker
        self.styled = styled
        self.reply = reply
        self.eventID = eventID
        self.isOwn = isOwn
        self.reactions = reactions
        self.status = status
        self.id = id
        self.style = style
        self.sender = sender
        self.text = text
        self.image = image
    }
}

/// Presents one room's timeline from `TimelineCoordinator` (docs/features/TIMELINE.md). M1: read-only.
@MainActor @Observable
public final class TimelineViewModel {
    public enum Content: Equatable {
        case opening
        case live(rows: [TimelineRow], isPaginating: Bool, canLoadEarlier: Bool, paginationError: String?)
        case failed(String)
    }

    public private(set) var content: Content = .opening
    /// The message being typed. Cleared only once the send was accepted, so a failure never loses the text.
    public var draft = "" {
        didSet {
            guard draft != oldValue, editing == nil, !isRestoringDraft else { return }
            saveDraft()
            if mentionQuery != nil { loadMembersIfNeeded() }
            let isTyping = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Task { [coordinator] in await coordinator.setTyping(isTyping) }
        }
    }
    /// People that can be mentioned in this room; loaded the first time the user types `@`.
    public private(set) var members: [RoomMember] = []
    private var membersRequested = false
    /// Users picked from the suggestions for the message being written.
    private var pendingMentions: [Mention] = []

    /// The text after a trailing `@` that starts a word in the draft, or `nil` when the user isn't typing a mention.
    public var mentionQuery: String? {
        guard editing == nil, let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace), query.count <= 30 else { return nil }
        return String(query)
    }

    /// Up to five members matching `mentionQuery`.
    public var mentionSuggestions: [RoomMember] {
        guard let query = mentionQuery else { return [] }
        let needle = query.lowercased()
        let matches = needle.isEmpty ? members : members.filter { member in
            member.mentionName.lowercased().contains(needle) || member.user.rawValue.lowercased().dropFirst().hasPrefix(needle)
        }
        return Array(matches.prefix(5))
    }

    /// Replaces the `@query` being typed with the member's name and remembers the mention for the send.
    public func pickMention(_ member: RoomMember) {
        guard mentionQuery != nil, let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(member.mentionName) "
        pendingMentions.removeAll { $0.user == member.user }
        pendingMentions.append(Mention(user: member.user, name: member.mentionName))
    }

    private func loadMembersIfNeeded() {
        guard !membersRequested else { return }
        membersRequested = true
        Task {
            if let loaded = try? await coordinator.members() { members = loaded } else { membersRequested = false }
        }
    }

    /// "Alice is typing…", or `nil` when nobody else is.
    public private(set) var typingText: String?
    public private(set) var isSending = false
    public private(set) var sendError: String?
    /// The own message being edited, or `nil` when the composer writes a new message.
    public private(set) var editing: EventID?
    /// The message an emoji is being picked for, or `nil` when the picker is closed.
    public private(set) var reactionTarget: TimelineRow?
    /// The emoji offered by the picker (a fixed set; the quick row of the menu is `quickReactions`).
    public static let quickReactions = ["👍", "❤️", "😂"]
    public static let pickerEmoji = [
        "👍", "👎", "❤️", "😂", "😮", "😢", "😡", "🎉", "🙏", "👏", "🔥", "💯", "✅", "❌", "👀", "🤔",
        "😀", "😅", "😉", "😍", "😘", "😎", "🥳", "😴", "🤯", "😬", "🙄", "🤗", "😇", "🤝", "💪", "🙌",
        "👋", "✌️", "👌", "🤞", "🫡", "🫶", "💔", "💙", "💚", "⭐️", "✨", "🚀", "☕️", "🍕", "🎂", "🌈",
    ]
    /// The message the next send replies to, or `nil`.
    public private(set) var replyingTo: TimelineRow?

    public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

    private let coordinator: TimelineCoordinator
    private let media: MediaLoader?
    private var observation: Task<Void, Never>?
    private let dateFormatter: DateFormatter
    private let receipts: ReadReceiptCoordinator?
    private let drafts: DraftCoordinator?
    private let room: RoomID?
    private let dwell: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var eventTimes: [EventID: Date] = [:]
    private var visible: Set<EventID> = []
    private var isActive = true
    private var clearedMarkedUnread = false
    private var isRestoringDraft = false
    /// The unsent text that was in the composer when an edit began; it comes back when the edit ends.
    private var stashedDraft = ""
    private var reportedOwn: EventID?
    private var dwellTask: Task<Void, Never>?
    private var pendingCandidate: EventID?

    /// How long an event must stay visible before it counts as seen (READ_RECEIPTS §1, D6).
    public static let seenDwell: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - drafts: when given together with `room`, the unsent text is kept per room (MESSAGING FR-5).
    ///   - receipts: when given together with `room`, the newest visible confirmed event is reported as read.
    public init(
        coordinator: TimelineCoordinator, media: MediaLoader? = nil, receipts: ReadReceiptCoordinator? = nil, room: RoomID? = nil,
        drafts: DraftCoordinator? = nil, dwell: Duration = TimelineViewModel.seenDwell, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        self.coordinator = coordinator
        self.media = media
        self.receipts = receipts
        self.room = room
        self.drafts = drafts
        self.dwell = dwell
        self.sleep = sleep
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        dateFormatter = formatter
    }

    isolated deinit { observation?.cancel(); dwellTask?.cancel() }

    // MARK: Read receipts

    /// The view reports a confirmed row entering or leaving the visible part of the list.
    public func rowVisibility(_ row: TimelineRow, isVisible: Bool) {
        guard let id = row.eventID else { return }
        if isVisible { visible.insert(id) } else { visible.remove(id) }
        reevaluateSeen()
    }

    /// `false` while the app isn't active or the room isn't the top-most screen; nothing is reported then.
    public func setActive(_ active: Bool) {
        isActive = active
        reevaluateSeen()
        clearMarkedUnreadIfVisible()
    }

    /// Opening a room clears `m.marked_unread` once the room is visible, once per opening of the screen.
    private func clearMarkedUnreadIfVisible() {
        guard isActive, !clearedMarkedUnread, observation != nil, let receipts, let room else { return }
        clearedMarkedUnread = true
        Task { await receipts.roomOpened(room) }
    }

    private func reevaluateSeen() {
        guard receipts != nil, room != nil else { return }
        let candidate = isActive ? visible.filter { eventTimes[$0] != nil }.max { eventTimes[$0]! < eventTimes[$1]! } : nil
        guard candidate != pendingCandidate else { return }
        pendingCandidate = candidate
        dwellTask?.cancel()
        dwellTask = nil
        guard let candidate, let time = eventTimes[candidate], let receipts, let room else { return }
        dwellTask = Task { [dwell, sleep] in
            do { try await sleep(dwell) } catch { return }
            await receipts.reportSeen(room: room, event: candidate, timestamp: time)
        }
    }

    /// Opens the timeline and follows it. Call when the screen appears.
    public func start() async {
        guard observation == nil else { return }
        await restoreDraft()
        let statuses = await coordinator.statuses()
        observation = Task { [weak self] in
            for await status in statuses { self?.apply(status) }
        }
        await coordinator.open()
        clearMarkedUnreadIfVisible()
    }

    private func restoreDraft() async {
        guard let drafts, let room else { return }
        let text = await drafts.draft(for: room)
        guard draft.isEmpty, editing == nil, !text.isEmpty else { return }
        isRestoringDraft = true
        draft = text
        isRestoringDraft = false
    }

    private func saveDraft() {
        guard let drafts, let room else { return }
        let text = draft
        Task { await drafts.save(text, for: room) }
    }

    /// Closes the timeline. Call when the screen disappears.
    public func stop() async {
        observation?.cancel()
        observation = nil
        clearedMarkedUnread = false
        await coordinator.close()
    }

    public func loadEarlier() async { await coordinator.paginateBackwards() }

    /// Sends the draft (MESSAGING FR-2). The message shows up in the timeline as a local echo.
    public func send() async {
        guard canSend else { return }
        let text = draft
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            if let editing {
                try await coordinator.edit(event: editing, newText: text)
                self.editing = nil
                draft = stashedDraft
                stashedDraft = ""
                return
            } else if let id = replyingTo?.eventID {
                try await coordinator.reply(to: id, text: text, mentions: pendingMentions)
                replyingTo = nil
            } else {
                try await coordinator.send(text, mentions: pendingMentions)
            }
            pendingMentions = []
            draft = ""
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. Your message was kept." : "The message couldn't be sent."
        }
    }

    /// Sends a sticker from the sticker panel. Throws so the panel can say it failed.
    public func sendSticker(_ sticker: Sticker) async throws(HaloError) {
        try await coordinator.sendSticker(sticker)
    }

    /// Reacts to a confirmed message, or removes the user's reaction.
    public func toggleReaction(on row: TimelineRow, key: String) async {
        guard let id = row.eventID else { return }
        await perform { try await coordinator.toggleReaction(on: id, key: key) }
    }

    /// Opens the emoji picker for a confirmed message.
    public func beginReactionPicker(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        reactionTarget = row
    }

    public func cancelReactionPicker() { reactionTarget = nil }

    /// Reacts with `key` to the picker's message and closes the picker.
    public func pickReaction(_ key: String) async {
        guard let target = reactionTarget else { return }
        reactionTarget = nil
        await toggleReaction(on: target, key: key)
    }

    /// Deletes the user's own confirmed message.
    public func delete(_ row: TimelineRow) async {
        guard let id = row.eventID, row.isOwn else { return }
        await perform { try await coordinator.delete(event: id) }
    }

    /// Sends a message that failed again.
    public func retry(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform { try await coordinator.retrySend(localID: id) }
    }

    /// Deletes a message that failed to send, so it never goes out.
    public func discard(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform { try await coordinator.abortSend(localID: id) }
    }

    /// Loads an own, confirmed text message into the composer for editing.
    public func beginEdit(_ row: TimelineRow) {
        guard let id = row.eventID, row.isOwn, row.style == .ownMessage, row.image == nil else { return }
        if editing == nil { stashedDraft = draft }
        editing = id
        replyingTo = nil
        draft = row.text.replacingOccurrences(of: " (edited)", with: "")
    }

    /// Makes the next send a reply to a confirmed message.
    public func beginReply(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        editing = nil
        replyingTo = row
    }

    public func cancelReply() { replyingTo = nil }

    public func cancelEdit() {
        editing = nil
        draft = stashedDraft
        stashedDraft = ""
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch {
            sendError = (error as? HaloError) == .forbidden ? "You can only change your own messages." : "That didn't work. Try again."
        }
    }

    /// Thumbnail bytes for an image row, or `nil` if it can't be loaded (the row then shows a placeholder).
    public func thumbnail(for image: TimelineRow.Image) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(image.ref, width: 600, height: 600)
    }

    func apply(_ status: TimelineCoordinator.Status) {
        switch status {
        case .idle, .opening:
            content = .opening
        case .live(let snapshot):
            var times: [EventID: Date] = [:]
            for item in snapshot.items {
                if case .event(let event) = item.content, let id = event.eventID { times[id] = event.timestamp }
            }
            eventTimes = times
            visible.formIntersection(times.keys)
            reportOwnMessage(snapshot.items)
            typingText = Self.typingText(snapshot.typing, items: snapshot.items)
            content = .live(
                rows: Self.collapsingStateRuns(snapshot.items.map(row), items: snapshot.items),
                isPaginating: snapshot.isPaginating,
                canLoadEarlier: !snapshot.reachedStart,
                paginationError: snapshot.paginationError.map { _ in "Couldn't load earlier messages." })
        case .failed(let error):
            content = .failed(error == .notFound ? "This room isn't available." : "The timeline couldn't be loaded.")
        }
    }

    /// Sending a message means the user has read up to it (MESSAGING FR-6, rule E1b): once the newest own message has a
    /// server event ID it becomes the read position. The coordinator ignores anything not newer than the current one.
    private func reportOwnMessage(_ items: [TimelineItem]) {
        guard let receipts, let room else { return }
        var newest: (id: EventID, time: Date)?
        for item in items {
            guard case .event(let event) = item.content, event.isOwn, let id = event.eventID else { continue }
            if newest == nil || event.timestamp > newest!.time { newest = (id, event.timestamp) }
        }
        guard let newest, newest.id != reportedOwn else { return }
        reportedOwn = newest.id
        Task { await receipts.reportSeen(room: room, event: newest.id, timestamp: newest.time) }
    }

    /// Names come from the timeline's senders; a user without one is shown by user ID (never invented).
    static func typingText(_ users: [UserID], items: [TimelineItem]) -> String? {
        guard !users.isEmpty else { return nil }
        var names: [UserID: String] = [:]
        for item in items {
            if case .event(let event) = item.content, let sender = event.sender, let name = event.senderName { names[sender] = name }
        }
        let labels = users.map { names[$0] ?? $0.rawValue }
        switch labels.count {
        case 1: return "\(labels[0]) is typing…"
        case 2: return "\(labels[0]) and \(labels[1]) are typing…"
        default: return "Several people are typing…"
        }
    }

    /// A run of unnamed room-setting changes (creation, power levels, join rules …) becomes one row
    /// (TIMELINE FR-2: state events grouped). Membership changes stay visible.
    static func collapsingStateRuns(_ rows: [TimelineRow], items: [TimelineItem]) -> [TimelineRow] {
        var result: [TimelineRow] = []
        for (row, item) in zip(rows, items) {
            let isSettings: Bool = { if case .event(let e) = item.content, e.kind == .otherState { true } else { false } }()
            if isSettings, let last = result.last, last.style == .state, last.text == Self.settingsText { continue }
            result.append(row)
        }
        return result
    }

    static let settingsText = "The room was updated"

    func row(_ item: TimelineItem) -> TimelineRow {
        let id = item.id.rawValue
        switch item.content {
        case .virtual(.dateDivider(let date)):
            return TimelineRow(id: id, style: .divider, sender: nil, text: dateFormatter.string(from: date))
        case .virtual(.readMarker):
            return TimelineRow(id: id, style: .marker, sender: nil, text: "New messages")
        case .virtual(.timelineStart):
            return TimelineRow(id: id, style: .state, sender: nil, text: "This is the start of the conversation.")
        case .event(let event):
            let name = event.senderName ?? event.sender.map { $0.rawValue } ?? "Unknown"
            switch event.kind {
            case .text(let body, let edited):
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: edited ? "\(body) (edited)" : body,
                    status: Self.status(of: event.sendState), eventID: event.eventID, isOwn: event.isOwn,
                    reactions: Self.chips(event.reactions), reply: Self.reply(event.replyTo),
                    styled: event.formattedBody.map { HTMLText.attributed($0) + AttributedString(edited ? " (edited)" : "") },
                    failedLocalID: Self.failedID(event))
            case .notice(let body, _):
                return TimelineRow(id: id, style: .notice, sender: name, text: body)
            case .emote(let body, _):
                return TimelineRow(id: id, style: .emote, sender: nil, text: "\(name) \(body)")
            case .media(let attachment):
                let style: TimelineRow.Style = event.isOwn ? .ownMessage : .message
                if attachment.kind == .image, let source = attachment.source {
                    let ratio: Double? = {
                    guard let width = attachment.width, let height = attachment.height, height > 0 else { return nil }
                    return Double(width) / Double(height)
                }()
                    return TimelineRow(
                        id: id, style: style, sender: name, text: attachment.body, image: .init(ref: source, aspectRatio: ratio),
                        eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions))
                }
                return TimelineRow(id: id, style: style, sender: name, text: "[\(Self.label(attachment.kind))] \(attachment.body)")
            case .sticker(let body, let source):
                guard let source else { return TimelineRow(id: id, style: .message, sender: name, text: "[Sticker] \(body)") }
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: body, image: .init(ref: source, aspectRatio: 1),
                    eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions), isSticker: true)
            case .redacted:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Message deleted")
            case .undecryptable(let reason):
                return TimelineRow(id: id, style: .placeholder, sender: name, text: Self.text(for: reason))
            case .membership(_, let displayName, let change):
                let who = displayName ?? name
                return TimelineRow(id: id, style: .state, sender: nil, text: "\(who) \(Self.phrase(change))")
            case .otherState:
                return TimelineRow(id: id, style: .state, sender: nil, text: Self.settingsText)
            case .unsupported:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Unsupported event")
            }
        }
    }

    static func reply(_ preview: ReplyPreview?) -> TimelineRow.Reply? {
        preview.map { TimelineRow.Reply(sender: $0.senderName, snippet: $0.snippet) }
    }

    static func chips(_ reactions: [ReactionSummary]) -> [TimelineRow.Chip] {
        reactions.map { TimelineRow.Chip(key: $0.key, count: $0.count, reactedByMe: $0.reactedByMe) }
    }

    /// The local ID of a failed own echo, the only kind the user can retry or delete.
    static func failedID(_ event: TimelineEvent) -> String? {
        if case .failed = event.sendState, event.eventID == nil { return event.localID }
        return nil
    }

    static func status(of state: SendState) -> String? {
        switch state {
        case .sent: nil
        case .sending: "Sending…"
        case .failed(let recoverable): recoverable ? "Not sent yet — will retry" : "Not sent"
        }
    }

    /// The reason is shown honestly; where the user can do something about it, the text says what.
    static func text(for reason: UTDReason) -> String {
        switch reason {
        case .unknown: "Unable to decrypt this message. It will appear if the keys arrive."
        case .sentBeforeJoining: "This message was sent before you joined, so you can't read it."
        case .keysNotShared: "Unable to decrypt: the sender's device hasn't shared its keys with this device yet."
        case .senderVerificationProblem: "Unable to decrypt: the sender's identity has changed or isn't verified."
        case .backupDisabled: "Unable to decrypt this older message. Verify this device with your recovery key to load your key backup."
        }
    }

    private static func label(_ kind: MediaKind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .file: "File"
        }
    }

    private static func phrase(_ change: MembershipChange) -> String {
        switch change {
        case .joined: "joined"
        case .left: "left"
        case .invited: "was invited"
        case .kicked: "was removed"
        case .banned: "was banned"
        case .unbanned: "was unbanned"
        case .invitationRejected: "declined the invitation"
        case .invitationRevoked: "had the invitation withdrawn"
        case .knocked: "asked to join"
        case .other: "changed their membership"
        }
    }
}
