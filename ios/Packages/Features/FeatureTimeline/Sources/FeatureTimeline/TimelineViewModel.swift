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
    /// A file, audio or video attachment, shown as a tile that opens in Quick Look (MEDIA_ATTACHMENTS FR-2…4).
    public let file: FileTile?

    /// What "View source" shows for a text message (BOT_MESSAGES FR-1): the sender, the event and both bodies, untouched.
    public struct Source: Equatable, Sendable {
        public let sender: String?
        public let eventID: String?
        public let body: String
        public let formattedBody: String?
    }

    /// Set for text messages and notices.
    public let source: Source?
    /// A known bot's message read as a structured card (BOT_MESSAGES Layer 2); `nil` for everything else.
    public let card: BotCard?
    /// The sender's profile picture, for someone else's message; the view shows their initial until it loads.
    public var avatar: MediaRef?
    /// Someone else's message that follows their previous one closely: the view leaves out the name and picture (one group).
    public var continuesRun = false
    /// The last message of a group: the view shows its time (`time`) under it.
    public var endsRun = true
    /// When it was sent, as a short time ("9:41 AM"); set for messages.
    public var time: String?

    public struct FileTile: Equatable, Sendable {
        public let kind: MediaKind
        public let name: String
        /// For example "PDF · 1.2 MB" or "0:42 · 3.4 MB".
        public let detail: String
        public let ref: MediaRef
        public let size: Int?
        /// A video's own still picture, shown above the tile (when the sender attached one).
        public let thumbnail: Image?
    }

    /// Whether the row shows its `text` in a bubble. A sticker never does, nor does a file tile, and neither does an image whose
    /// body is just its file name ("photo.jpg", which clients put in `body` when there is no caption); a real caption is shown.
    public var showsText: Bool { !isSticker && file == nil && !(image != nil && Self.looksLikeFilename(text)) }

    static func looksLikeFilename(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else { return false }
        let ext = trimmed[trimmed.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
    }

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
        failedLocalID: String? = nil, isSticker: Bool = false, file: FileTile? = nil, source: Source? = nil, card: BotCard? = nil
    ) {
        self.card = card
        self.source = source
        self.file = file
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
    /// User IDs of bots whose messages may become cards (Settings → Bots, BOT_MESSAGES §3).
    public var botSenders: Set<String> = []
    /// Reports a known bot's message whose formatted body no template recognised (by event ID; for the diagnostics count).
    public var unrecognisedBotMessages: UnrecognisedBotMessages?
    /// What the room's bot messages say about tasks (BOT_MESSAGES §6); recomputed with every snapshot.
    public private(set) var botTasks = BotTaskTracker([])
    /// Tasks the user ticked and the bot hasn't confirmed yet, and those that got no answer in time.
    private var botTapped: Set<BotTaskTracker.Key> = []
    private var botUnanswered: Set<BotTaskTracker.Key> = []
    private var botTimeouts: [BotTaskTracker.Key: Task<Void, Never>] = [:]
    /// How long to wait for the bot before showing "No response from bot" (BOT_MESSAGES §6).
    var botTimeout: Duration = .seconds(120)

    public enum BotRowState: Equatable, Sendable {
        /// Can be ticked.
        case open
        /// The 👍 was sent; waiting for the bot's confirmation.
        case pending
        /// No confirmation within the timeout; tapping again is allowed.
        case noResponse
        case completed
        /// The creating message isn't known, so there is nothing to react to: read-only (AC-B3).
        case unavailable
    }

    /// The state of one row of a bot's todo list.
    public func botRowState(bot: String?, id: String) -> BotRowState {
        guard let bot else { return .unavailable }
        let key = BotTaskTracker.Key(bot: bot, id: id)
        if botTasks.isCompleted(key) { return .completed }
        guard botTasks.source(of: key) != nil else { return .unavailable }
        if botTapped.contains(key) { return .pending }
        return botUnanswered.contains(key) ? .noResponse : .open
    }

    /// Ticks a row: one 👍 on the message that created the task, never on the list (BOT_MESSAGES FR-3). Ignored while pending,
    /// done or unavailable, and no second 👍 is sent when the user already has one on that message.
    public func tickBotTask(bot: String?, id: String) async {
        guard let bot else { return }
        let state = botRowState(bot: bot, id: id)
        guard state == .open || state == .noResponse else { return }
        let key = BotTaskTracker.Key(bot: bot, id: id)
        guard let source = botTasks.source(of: key) else { return }
        botUnanswered.remove(key)
        botTapped.insert(key)
        let alreadyReacted: Bool = {
            guard case .live(let rows, _, _, _) = content, let target = rows.first(where: { $0.eventID == source.eventID }) else { return false }
            return target.reactions.contains { $0.key == "👍" && $0.reactedByMe }
        }()
        if !alreadyReacted {
            do { try await coordinator.toggleReaction(on: source.eventID, key: "👍") } catch {
                botTapped.remove(key)
                sendError = "That didn't work. Try again."
                return
            }
        }
        botTimeouts[key]?.cancel()
        let timeout = botTimeout
        botTimeouts[key] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.botTimedOut(key)
        }
    }

    private func botTimedOut(_ key: BotTaskTracker.Key) {
        guard botTapped.remove(key) != nil else { return }
        botUnanswered.insert(key)
        botTimeouts[key] = nil
    }
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

    public var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingPhoto != nil) && !isSending && !isSendingImage
    }

    private let coordinator: TimelineCoordinator
    private let media: MediaLoader?
    private let previewsAllowed: (@Sendable () async -> Bool)?
    /// `true` when the account's media preview setting asks for a tap before photos in this room are shown (FR-7).
    public private(set) var previewsHidden = false
    private var revealedPreviews: Set<MediaRef> = []
    private var observation: Task<Void, Never>?
    private let dateFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let receipts: ReadReceiptCoordinator?
    private let drafts: DraftCoordinator?
    private let imagePreparer: (any ImagePreparing)?
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
    private let readThrough: (@Sendable () async -> Date?)?
    /// The time up to which the user had read the room when it was opened (nil: unknown, then the timeline opens at the bottom).
    var readThroughAtOpen: Date?
    private var landed = false
    /// The row to bring to the top of the screen once, right after the timeline first shows items (the first unread message).
    public private(set) var landingRow: String?
    /// `true` when `landingRow` is the first unread message (shown at the top); `false` when it is the newest row (shown at the bottom).
    public private(set) var landingIsUnread = false
    /// The first message that was unread when the room was opened (TIMELINE FR-4): the "Jump to unread" pill leads back to it for as
    /// long as the room stays open (the SDK's own "New messages" row moves with the fully-read marker). `nil` when nothing was unread or the position is unknown.
    public private(set) var unreadMarkerID: String?

    /// How long an event must stay visible before it counts as seen (READ_RECEIPTS §1, D6).
    public static let seenDwell: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - drafts: when given together with `room`, the unsent text is kept per room (MESSAGING FR-5).
    ///   - images: prepares picked photos for sending; without it the composer offers no photo button.
    ///   - receipts: when given together with `room`, the newest visible confirmed event is reported as read.
    public init(
        coordinator: TimelineCoordinator, media: MediaLoader? = nil, previewsAllowed: (@Sendable () async -> Bool)? = nil, receipts: ReadReceiptCoordinator? = nil, room: RoomID? = nil,
        drafts: DraftCoordinator? = nil, images: (any ImagePreparing)? = nil, readThrough: (@Sendable () async -> Date?)? = nil, dwell: Duration = TimelineViewModel.seenDwell, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        self.coordinator = coordinator
        self.media = media
        self.previewsAllowed = previewsAllowed
        self.receipts = receipts
        self.room = room
        self.drafts = drafts
        self.imagePreparer = images
        self.readThrough = readThrough
        self.dwell = dwell
        self.sleep = sleep
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        dateFormatter = formatter
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        timeFormatter = time
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
        // The saved draft is not needed to show messages: restore it while the timeline opens.
        let draftRestored = Task { await restoreDraft() }
        readThroughAtOpen = await readThrough?()
        if let previewsAllowed { previewsHidden = await !previewsAllowed() }
        landed = false
        landingRow = nil
        unreadMarkerID = nil
        let statuses = await coordinator.statuses()
        observation = Task { [weak self] in
            for await status in statuses { self?.apply(status) }
        }
        await coordinator.open()
        await draftRestored.value
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

    /// The id of the newest row on screen, or `nil` while there are none.
    public var lastRowID: String? {
        if case .live(let rows, _, _, _) = content { return rows.last?.id }
        return nil
    }

    /// The view has scrolled to the landing row.
    public func landingShown() { landingRow = nil }

    /// The first message from someone else newer than `readThrough` (TIMELINE FR "land at the first unread message"); `nil` when
    /// the read position is unknown or nothing is unread, in which case the timeline stays at the bottom.
    nonisolated static func firstUnreadItemID(_ items: [TimelineItem], readThrough: Date?) -> String? {
        guard let readThrough else { return nil }
        for item in items {
            guard case .event(let event) = item.content, !event.isOwn, event.timestamp > readThrough else { continue }
            switch event.kind {
            case .text, .notice, .emote, .media, .sticker: return item.id.rawValue
            default: continue
            }
        }
        return nil
    }

    // MARK: Opening files

    /// A downloaded copy of an attachment, in a temporary folder, shown in Quick Look.
    public struct OpenedFile: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL
    }

    public private(set) var openedFile: OpenedFile?
    /// The id of the row whose file is downloading.
    public private(set) var openingRow: String?
    public private(set) var openFileError: String?
    /// Files are read into memory whole for now (`MediaPort.content`); bigger ones wait for a file-based download.
    public static let openSizeLimit = 50 * 1024 * 1024

    public func openFile(_ row: TimelineRow) async {
        guard let file = row.file, let media, openingRow == nil else { return }
        openFileError = nil
        if let size = file.size, size > Self.openSizeLimit {
            openFileError = "This file is too large to open here yet (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        openingRow = row.id
        defer { openingRow = nil }
        do {
            let data = try await media.content(file.ref)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-open-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The name comes from the sender: keep only its last path component so it can't leave the folder.
            let last = URL(fileURLWithPath: file.name).lastPathComponent
            let url = directory.appendingPathComponent(last.isEmpty || last == "." || last == ".." ? "file" : last)
            try data.write(to: url, options: .atomic)
            openedFile = OpenedFile(url: url)
        } catch {
            openFileError = (error as? HaloError) == .network(retryable: true) ? "Can't reach the server. The file wasn't opened." : "The file couldn't be opened."
        }
    }

    /// Quick Look was dismissed: the temporary copy is deleted.
    public func closeFile() {
        if let url = openedFile?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        openedFile = nil
    }

    public func dismissOpenFileError() { openFileError = nil }

    public func loadEarlier() async { await coordinator.paginateBackwards() }

    /// Sends the draft (MESSAGING FR-2). The message shows up in the timeline as a local echo.
    public func send() async {
        guard canSend else { return }
        if let photo = pendingPhoto { await sendPendingPhoto(photo); return }
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

    /// `true` when the composer can attach photos.
    public var canSendImages: Bool { imagePreparer != nil }
    /// A photo is being prepared or uploaded.
    public private(set) var isSendingImage = false

    /// A photo that was picked and prepared but not sent yet; the composer text becomes its caption when it is sent (FR-2).
    public private(set) var pendingPhoto: OutgoingImage?

    /// Prepares a picked photo and holds it in the composer, so a caption can be typed before sending.
    public func attachPhoto(data: Data, filename: String) async {
        guard let imagePreparer, !isSendingImage else { return }
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        do { pendingPhoto = try await Self.prepare(imagePreparer, data, filename) } catch {
            sendError = error == .invalidInput("NOT_AN_IMAGE") ? "That file isn't a picture." : error == .invalidInput("IMAGE_TOO_LARGE") ? "That picture is too large to send." : "That picture couldn't be read."
        }
    }

    /// Drops the held photo; the typed text stays.
    public func removePendingPhoto() { pendingPhoto = nil }

    /// Sends the held photo with the composer text as its caption. A failure keeps both, so nothing typed is lost.
    private func sendPendingPhoto(_ photo: OutgoingImage) async {
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let captioned = OutgoingImage(data: photo.data, filename: photo.filename, mimeType: photo.mimeType, width: photo.width, height: photo.height, caption: text.isEmpty ? nil : text)
        do {
            try await coordinator.sendImage(captioned)
            pendingPhoto = nil
            draft = ""
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. The picture wasn't sent." : "The picture couldn't be sent."
        }
    }

    /// Sends a picked photo: shrinks it, strips its metadata, uploads it. The message shows as a local echo while uploading.
    public func sendImage(data: Data, filename: String) async {
        guard let imagePreparer, !isSendingImage else { return }
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        do {
            let image = try await Self.prepare(imagePreparer, data, filename)
            try await coordinator.sendImage(image)
        } catch {
            switch error {
            case .invalidInput("NOT_AN_IMAGE"): sendError = "That file isn't a picture."
            case .invalidInput("IMAGE_TOO_LARGE"): sendError = "That picture is too large to send."
            case .network(retryable: true): sendError = "Can't reach the server. The picture wasn't sent."
            default: sendError = "The picture couldn't be sent."
            }
        }
    }

    public private(set) var isSendingFile = false

    /// Sends a picked file, recording or clip as it is. The message shows as a local echo while uploading.
    public func sendFile(data: Data, filename: String, mimeType: String) async {
        guard !isSendingFile else { return }
        isSendingFile = true
        sendError = nil
        defer { isSendingFile = false }
        do {
            try await coordinator.sendFile(OutgoingFile(data: data, filename: filename, mimeType: mimeType))
        } catch {
            switch error {
            case .invalidInput("FILE_TOO_LARGE"): sendError = "That file is too large to send."
            case .invalidInput("EMPTY_FILE"): sendError = "That file is empty."
            case .invalidInput: sendError = "That file can't be sent."
            case .network(retryable: true): sendError = "Can't reach the server. The file wasn't sent."
            default: sendError = "The file couldn't be sent."
            }
        }
    }

    public func reportFileTooLarge() { sendError = "That file is too large to send." }
    public func reportFileUnreadable() { sendError = "That file couldn't be read." }

    /// Decoding and re-encoding a photo is real work; it runs off the main actor.
    @concurrent private static func prepare(_ preparer: any ImagePreparing, _ data: Data, _ filename: String) async throws(HaloError) -> OutgoingImage {
        try preparer.prepare(data: data, filename: filename)
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

    /// Whether the photo is shown: always, unless the media preview setting hides photos and this one wasn't tapped.
    public func showsPreview(of image: TimelineRow.Image) -> Bool { !previewsHidden || revealedPreviews.contains(image.ref) }

    /// The user tapped a hidden photo: it loads and stays shown while the room is open.
    public func revealPreview(of image: TimelineRow.Image) { revealedPreviews.insert(image.ref) }

    /// A sender's profile picture, small; `nil` if it can't be loaded (the view keeps the initial).
    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 64, height: 64)
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
            botTasks = botTracker(snapshot.items)
            botTapped.subtract(botTasks.completed)
            botUnanswered.subtract(botTasks.completed)
            let rows = Self.collapsingStateRuns(Self.groupingRuns(snapshot.items.map(row), items: snapshot.items), items: snapshot.items)
            // Wait until there is something to land on: a message, or the whole (message-less) history. The first snapshots of a
            // freshly opened room hold only the start marker and state events.
            let hasMessage = snapshot.items.contains { item in
                if case .event(let event) = item.content { switch event.kind { case .text, .notice, .emote, .media, .sticker: return true; default: return false } }
                return false
            }
            if !landed, !rows.isEmpty, hasMessage || (snapshot.reachedStart && !snapshot.isPaginating) {
                landed = true
                if let unread = Self.firstUnreadItemID(snapshot.items, readThrough: readThroughAtOpen) {
                    landingRow = unread
                    landingIsUnread = true
                    unreadMarkerID = unread
                } else {
                    landingRow = rows.last?.id  // all read, or the position is unknown: the bottom
                    landingIsUnread = false
                }
            }
            visible.formIntersection(times.keys)
            reportOwnMessage(snapshot.items)
            typingText = Self.typingText(snapshot.typing, items: snapshot.items)
            content = .live(
                rows: rows,
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

    /// Messages from the same person within this time of their previous one form a group (one name and picture).
    static let runGap: TimeInterval = 5 * 60

    /// Marks a message that directly follows the same person's previous message (no divider or other row between, within
    /// `runGap`), so the view shows the name and picture once per group and the time once, under its last message.
    static func groupingRuns(_ rows: [TimelineRow], items: [TimelineItem]) -> [TimelineRow] {
        var result = rows
        let isMessage: (TimelineRow) -> Bool = { $0.style == .message || $0.style == .ownMessage }
        for index in result.indices.dropFirst() where isMessage(result[index]) && result[index - 1].style == result[index].style {
            guard case .event(let event) = items[index].content, case .event(let previous) = items[index - 1].content,
                  let sender = event.sender, sender == previous.sender,
                  event.timestamp.timeIntervalSince(previous.timestamp) < runGap else { continue }
            result[index].continuesRun = true
            result[index - 1].endsRun = false
        }
        return result
    }

    private func botTracker(_ items: [TimelineItem]) -> BotTaskTracker {
        guard !botSenders.isEmpty else { return BotTaskTracker([]) }
        var messages: [BotTaskTracker.Message] = []
        for item in items {
            guard case .event(let event) = item.content, let card = botCard(event), let sender = event.sender?.rawValue else { continue }
            messages.append(.init(bot: sender, eventID: event.eventID, card: card))
        }
        return BotTaskTracker(messages)
    }

    /// The card for a message from an allowlisted bot whose HTML a parser recognises.
    private func botCard(_ event: TimelineEvent) -> BotCard? {
        guard let sender = event.sender?.rawValue, botSenders.contains(sender), let html = event.formattedBody else { return nil }
        let card = BotTemplates.parse(html)
        if card == nil, let id = event.eventID?.rawValue { unrecognisedBotMessages?.record(eventID: id) }
        return card
    }

    private func plainSource(_ event: TimelineEvent, _ body: String) -> TimelineRow.Source {
        .init(sender: event.sender?.rawValue, eventID: event.eventID?.rawValue, body: body, formattedBody: event.formattedBody)
    }

    func row(_ item: TimelineItem) -> TimelineRow {
        var row = baseRow(item)
        if case .event(let event) = item.content {
            if !event.isOwn { row.avatar = event.senderAvatar }
            if row.style == .message || row.style == .ownMessage { row.time = timeFormatter.string(from: event.timestamp) }
        }
        return row
    }

    private func baseRow(_ item: TimelineItem) -> TimelineRow {
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
                    failedLocalID: Self.failedID(event),
                    source: .init(sender: event.sender?.rawValue, eventID: event.eventID?.rawValue, body: body, formattedBody: event.formattedBody),
                    card: botCard(event))
            case .notice(let body, _):
                return TimelineRow(
                    id: id, style: .notice, sender: name, text: body,
                    source: .init(sender: event.sender?.rawValue, eventID: event.eventID?.rawValue, body: body, formattedBody: event.formattedBody))
            case .emote(let body, _):
                return TimelineRow(id: id, style: .emote, sender: nil, text: "\(name) \(body)", source: plainSource(event, body))
            case .media(let attachment):
                let style: TimelineRow.Style = event.isOwn ? .ownMessage : .message
                if attachment.kind == .image, let source = attachment.source {
                    let ratio = Self.aspectRatio(width: attachment.width, height: attachment.height)
                    return TimelineRow(
                        id: id, style: style, sender: name, text: attachment.body, image: .init(ref: source, aspectRatio: ratio),
                        eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions), source: plainSource(event, attachment.body))
                }
                let label = "[\(Self.label(attachment.kind))] \(attachment.body)"
                guard let source = attachment.source else { return TimelineRow(id: id, style: style, sender: name, text: label) }
                return TimelineRow(
                    id: id, style: style, sender: name, text: label, eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions),
                    file: .init(kind: attachment.kind, name: attachment.body, detail: Self.fileDetail(attachment), ref: source, size: attachment.size,
                        thumbnail: attachment.kind == .video ? attachment.thumbnail.map { .init(ref: $0, aspectRatio: Self.aspectRatio(width: attachment.width, height: attachment.height)) } : nil), source: plainSource(event, attachment.body))
            case .sticker(let body, let source):
                guard let source else {
                    return TimelineRow(
                        id: id, style: event.isOwn ? .ownMessage : .message, sender: name,
                        text: body.isEmpty ? "Sticker (can't be shown)" : "[Sticker] \(body)", eventID: event.eventID, isOwn: event.isOwn)
                }
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: body, image: .init(ref: source, aspectRatio: 1),
                    eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions), isSticker: true, source: plainSource(event, body))
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

    /// "PDF · 1.2 MB", "0:42 · 3.4 MB": what is known about the file, without inventing the rest.
    static func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    static func fileDetail(_ attachment: MediaAttachment) -> String {
        var parts: [String] = []
        if let duration = attachment.duration, duration > 0, attachment.kind != .file {
            let total = Int(duration.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if attachment.kind == .file {
            let ext = (attachment.body as NSString).pathExtension
            if !ext.isEmpty { parts.append(ext.uppercased()) }
            else if let mime = attachment.mimeType, let sub = mime.split(separator: "/").last { parts.append(sub.uppercased()) }
        }
        if let size = attachment.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: " · ")
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
