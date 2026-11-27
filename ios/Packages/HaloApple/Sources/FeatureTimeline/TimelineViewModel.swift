import Foundation
import HaloApplication
import HaloBotRendering
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import Observation

@MainActor @Observable
public final class TimelineViewModel {
    public enum Content: Equatable {
        case opening
        case live(rows: [TimelineRow], isPaginating: Bool, canLoadEarlier: Bool, paginationError: String?)
        case failed(String)
    }

    public internal(set) var content: Content = .opening
    /// User IDs of bots whose messages may become cards (Settings → Bots, BOT_MESSAGES §3).
    public var botSenders: Set<String> = []
    /// Reports a known bot's message whose formatted body no template recognised (by event ID; for the diagnostics count).
    public var unrecognisedBotMessages: UnrecognisedBotMessages?
    /// Receives every snapshot of this room so the Activity index learns the bots' tasks (BOT_ACTIVITY FR-1).
    public var botActivity: BotActivityCoordinator?
    /// What the room's bot messages say about tasks (BOT_MESSAGES §6); recomputed with every snapshot.
    public internal(set) var botTasks = BotTaskTracker([])
    /// Tasks the user ticked and the bot hasn't confirmed yet, and those that got no answer in time.
    var botTapped: Set<BotTaskTracker.Key> = []
    var botUnanswered: Set<BotTaskTracker.Key> = []
    var botTimeouts: [BotTaskTracker.Key: Task<Void, Never>] = [:]
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

    func botTimedOut(_ key: BotTaskTracker.Key) {
        guard botTapped.remove(key) != nil else { return }
        botUnanswered.insert(key)
        botTimeouts[key] = nil
    }
    /// Whether typing notices are sent while the user composes (Settings → Privacy → Typing notices, SETTINGS §3).
    public var sendsTypingNotices: @MainActor () -> Bool = { true }
    /// KLIPY GIFs and stickers (D98); `nil` hides them, and KLIPY links then show as plain links.
    public var klipy: KlipyCatalog?

    /// The Article editor's text (D101): kept while the editor is closed, cleared once the article was sent.
    public var articleDraft = ""

    /// The message being typed. Cleared only once the send was accepted, so a failure never loses the text.
    public var draft = "" {
        didSet {
            guard draft != oldValue, editing == nil, !isRestoringDraft else { return }
            saveDraft()
            if mentionQuery != nil { loadMembersIfNeeded() }
            let isTyping = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if sendsTypingNotices() {
                Task { [coordinator] in await coordinator.setTyping(isTyping) }
            } else if !isTyping {
                // If disabled mid-draft, still clear any typing notice already sent; no-op when none was sent.
                Task { [coordinator] in await coordinator.setTyping(false) }
            }
        }
    }
    /// People that can be mentioned in this room; loaded the first time the user types `@`.
    public internal(set) var members: [RoomMember] = []
    var membersRequested = false
    /// Users picked from the suggestions for the message being written.
    var pendingMentions: [Mention] = []

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

    func loadMembersIfNeeded() {
        guard !membersRequested else { return }
        membersRequested = true
        Task {
            if let loaded = try? await coordinator.members() { members = loaded } else { membersRequested = false }  // best-effort: a read or a cache; a miss changes nothing the person sees
        }
    }

    /// Up to six native emoji matching a trailing `:shortcode` query in `draft`.
    public var emojiSuggestions: [NativeEmoji.Entry] {
        NativeEmoji.shortcodeSuggestions(forDraft: draft)?.entries ?? []
    }

    /// Replaces the trailing `:shortcode` in `draft` with the selected native emoji and records it as recent.
    public func pickEmojiSuggestion(_ entry: NativeEmoji.Entry) {
        guard let match = NativeEmoji.shortcodeSuggestions(forDraft: draft) else { return }
        draft.replaceSubrange(match.range, with: entry.emoji + " ")
        recordRecentEmoji(entry.emoji)
    }

    /// Inserts a native emoji into the composer draft and records it as recent.
    public func insertEmoji(_ emoji: String) {
        draft += emoji
        recordRecentEmoji(emoji)
    }

    /// Most recently used native emoji for reactions and composer input (persisted per device, newest first, max 16).
    public internal(set) var recentEmoji: [String] = UserDefaults.standard.stringArray(forKey: "halo.emoji.recents") ?? []

    func recordRecentEmoji(_ emoji: String) {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentEmoji.removeAll { $0 == trimmed }
        recentEmoji.insert(trimmed, at: 0)
        if recentEmoji.count > 16 { recentEmoji.removeLast(recentEmoji.count - 16) }
        UserDefaults.standard.set(recentEmoji, forKey: "halo.emoji.recents")
    }

    /// "Alice is typing…", or `nil` when nobody else is.
    public internal(set) var typingText: String?
    /// Contacts whose identity changed and wasn't accepted yet, shown above the composer until handled (FR-7, AC-SEC-1).
    public internal(set) var identityNotices: [IdentityNotice] = []
    /// Names of the loaded timeline's senders, for the reasons a send was refused.
    var senderNames: [UserID: String] = [:]
    public internal(set) var isSending = false
    public internal(set) var sendError: String?
    /// Double-tap protection for changes to messages (AC-REL-4).
    let actions = ActionGuard()
    /// The own message being edited, or `nil` when the composer writes a new message.
    public internal(set) var editing: EventID?
    /// The message an emoji is being picked for, or `nil` when the picker is closed.
    public internal(set) var reactionTarget: TimelineRow?
    /// The emoji offered by the picker (a fixed set; the quick row of the menu is `quickReactions`).
    public static let quickReactions = ["👍", "❤️", "😂"]
    public static let pickerEmoji = [
        "👍", "👎", "❤️", "😂", "😮", "😢", "😡", "🎉", "🙏", "👏", "🔥", "💯", "✅", "❌", "👀", "🤔",
        "😀", "😅", "😉", "😍", "😘", "😎", "🥳", "😴", "🤯", "😬", "🙄", "🤗", "😇", "🤝", "💪", "🙌",
        "👋", "✌️", "👌", "🤞", "🫡", "🫶", "💔", "💙", "💚", "⭐️", "✨", "🚀", "☕️", "🍕", "🎂", "🌈",
    ]
    /// The message the next send replies to, or `nil`.
    public internal(set) var replyingTo: TimelineRow?

    public var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingPhotos.isEmpty) && !isSending && !isSendingImage
    }

    let coordinator: TimelineCoordinator
    let media: MediaLoader?
    let previewsAllowed: (@Sendable () async -> Bool)?
    /// `true` when the account's media preview setting asks for a tap before photos in this room are shown (FR-7).
    public internal(set) var previewsHidden = false
    var revealedPreviews: Set<MediaRef> = []
    /// Pictures already shown (`TimelineThumbnailMemory`) and the photo reference last seen per row, to carry a sent photo
    /// from its local echo to the confirmed message.
    let thumbnailMemory: TimelineThumbnailMemory
    var knownPhotoRefs: [String: MediaRef] = [:]
    /// The row made for each item the last time, reused while the item and what the mapping reads besides it are unchanged
    /// (M19-2): a new message maps one row, not the whole room.
    var rowCache: [TimelineItemID: (item: TimelineItem, row: TimelineRow)] = [:]
    var rowCacheContext = 0
    /// How many rows `row(_:)` made through `mappedRows`; the test that pins M19-2 reads it.
    var rowsMapped = 0
    var observation: Task<Void, Never>?
    let dateFormatter: DateFormatter
    let timeFormatter: DateFormatter
    let editTimeFormatter: DateFormatter
    let receipts: ReadReceiptCoordinator?
    let drafts: DraftCoordinator?
    let imagePreparer: (any ImagePreparing)?
    let room: RoomID?
    let dwell: Duration
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date
    var readTracker = TimelineReadTracker()
    var isActive = true
    /// `false` while the model was started ahead of its screen (`startAhead`, a warm model for the top of the chat list, M19-9):
    /// it then reports nothing, no read receipt, no seen event, no own message as read, no `m.marked_unread` clearing.
    public internal(set) var isPresented = true
    /// Told once when a model started ahead of its screen is shown (`present`).
    public var onPresented: (@MainActor () -> Void)?
    /// The items of the last live snapshot, for what is worked out again when a model started ahead is shown.
    var lastItems: [TimelineItem] = []
    var clearedMarkedUnread = false
    var isRestoringDraft = false
    /// The unsent text that was in the composer when an edit began; it comes back when the edit ends.
    var stashedDraft = ""
    var reportedOwn: EventID?
    var dwellTask: Task<Void, Never>?
    var pendingCandidate: EventID?
    let readThrough: (@Sendable () async -> Date?)?
    /// The time up to which the user had read the room when it was opened (nil: unknown, then the timeline opens at the bottom).
    var readThroughAtOpen: Date?
    var landed = false
    /// Pages loaded at open to find a message when the loaded history holds only room events (a join): without it a room
    /// whose newest events are state events never lands, and history only loads after landing.
    var openingPages = 0
    static let maxOpeningPages = 10
    /// The row to bring to the top of the screen once, right after the timeline first shows items (the first unread message).
    public internal(set) var landingRow: String?
    /// `true` when `landingRow` is the first unread message (shown at the top); `false` when it is the newest row (shown at the bottom).
    public internal(set) var landingIsUnread = false
    /// The first message that was unread when the room was opened (TIMELINE FR-4): the "Jump to unread" pill leads back to it for as
    /// long as the room stays open (the SDK's own "New messages" row moves with the fully-read marker). `nil` when nothing was unread or the position is unknown.
    public internal(set) var unreadMarkerID: String?
    /// Set by `jumpToReplyOriginal`; the view scrolls to this row and clears it with `jumpHandled`.
    public internal(set) var jumpRequest: String?
    /// The row a reply jump just landed on; shown highlighted until `clearHighlight`.
    public internal(set) var highlightedRowID: String?
    /// `true` while the newest row is in view; `false` when the user scrolled up to read history (TIMELINE §6: Detached).
    public internal(set) var isAtBottom = true
    /// Number of incoming messages appended while the user is scrolled up (`!isAtBottom`). Cleared on returning to the bottom.
    public internal(set) var newSinceDetached = 0
    /// Event IDs currently pinned in the room (`m.room.pinned_events`).
    public internal(set) var pinnedEventIDs: [EventID] = []
    var trackedTailID: String?

    /// How long an event must stay visible before it counts as seen (READ_RECEIPTS §1, D6).
    public static let seenDwell: Duration = .milliseconds(500)

    /// - Parameters:
    ///   - drafts: when given together with `room`, the unsent text is kept per room (MESSAGING FR-5).
    ///   - images: prepares picked photos for sending; without it the composer offers no photo button.
    ///   - receipts: when given together with `room`, the newest visible confirmed event is reported as read.
    ///   - thumbnails: the pictures already shown, shared by the app's timelines; a model of its own when not given.
    public init(
        coordinator: TimelineCoordinator, media: MediaLoader? = nil, previewsAllowed: (@Sendable () async -> Bool)? = nil, receipts: ReadReceiptCoordinator? = nil, room: RoomID? = nil,
        drafts: DraftCoordinator? = nil, images: (any ImagePreparing)? = nil, readThrough: (@Sendable () async -> Date?)? = nil, dwell: Duration = TimelineViewModel.seenDwell, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        locale: Locale = .current, timeZone: TimeZone = .current, thumbnails: TimelineThumbnailMemory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.thumbnailMemory = thumbnails ?? TimelineThumbnailMemory()
        self.media = media
        self.previewsAllowed = previewsAllowed
        self.receipts = receipts
        self.room = room
        self.drafts = drafts
        self.imagePreparer = images
        self.readThrough = readThrough
        self.dwell = dwell
        self.sleep = sleep
        self.now = now
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
        let edit = DateFormatter()
        edit.locale = time.locale
        edit.timeZone = time.timeZone
        edit.dateStyle = .medium
        edit.timeStyle = .short
        editTimeFormatter = edit
    }

    isolated deinit { observation?.cancel(); dwellTask?.cancel() }

    // MARK: Read receipts

    /// The view reports a confirmed row entering or leaving the visible part of the list.
    public func rowVisibility(_ row: TimelineRow, isVisible: Bool) {
        guard let id = row.eventID else { return }
        readTracker.setVisible(id, isVisible: isVisible)
        reevaluateSeen()
    }

    /// `false` while the app isn't active or the room isn't the top-most screen; nothing is reported then.
    public func setActive(_ active: Bool) {
        isActive = active
        reevaluateSeen()
        clearMarkedUnreadIfVisible()
    }

    /// Opening a room clears `m.marked_unread` once the room is visible, once per opening of the screen.
    func clearMarkedUnreadIfVisible() {
        guard isActive, isPresented, !clearedMarkedUnread, observation != nil, let receipts, let room else { return }
        clearedMarkedUnread = true
        Task { await receipts.roomOpened(room) }
    }

    func reevaluateSeen() {
        guard receipts != nil, room != nil, !isFocused, !receiptsWait else { return }
        let candidate = readTracker.candidate(isActive: isActive && isPresented)
        guard candidate?.event != pendingCandidate else { return }
        pendingCandidate = candidate?.event
        dwellTask?.cancel()
        dwellTask = nil
        guard let candidate, let receipts, let room else { return }
        let coordinator = coordinator
        dwellTask = Task { [weak self, dwell, sleep] in
            do { try await sleep(dwell) } catch { return }
            guard !Task.isCancelled else { return }
            // When the user has viewed the newest visible row at the tail, cover any trailing hidden event (such as an
            // encrypted poll vote) by targeting `Timeline.latestEventId()` (R-01 leftover, R-06).
            let targetEvent: EventID
            if candidate.isAtTail, let latest = await coordinator.latestEventID() {
                targetEvent = latest
            } else {
                targetEvent = candidate.event
            }
            self?.readTracker.markReported(candidate.event)
            await receipts.reportSeen(
                room: room, event: targetEvent, timestamp: candidate.timestamp,
                advancesOrder: candidate.advancesOrder || targetEvent != candidate.event)
        }
    }

    /// Opens the timeline and follows it. Call when the screen appears. A start already under way (`startAhead`) is awaited, not
    /// repeated.
    public func start() async {
        if let starting {
            await starting.value
            return
        }
        guard observation == nil else { return }
        let task = Task { await opening() }
        starting = task
        await task.value
        starting = nil
    }

    /// The start under way, so a second caller waits for it instead of opening the timeline twice.
    var starting: Task<Void, Never>?
    /// Told once each when a screen shown now would draw the room at once (`canShow`).
    var showableWaiters: [@MainActor () -> Void] = []

    /// A screen shown now would draw rows at the place it lands, or the failure, on its first frame (M19-9).
    public var canShow: Bool {
        if case .failed = content { return true }
        return landed
    }

    /// Calls `action` once `canShow` holds (at once if it does now).
    func whenShowable(_ action: @escaping @MainActor () -> Void) {
        if canShow { action() } else { showableWaiters.append(action) }
    }

    func noteIfShowable() {
        guard canShow, !showableWaiters.isEmpty else { return }
        let waiting = showableWaiters
        showableWaiters = []
        for action in waiting { action() }
    }
    /// `present()` ran: a start ahead that only runs afterwards must not hide the screen's model again.
    var wasPresented = false

    private func opening() async {
        // The saved draft is not needed to show messages: restore it while the timeline opens.
        let draftRestored = Task { await restoreDraft() }
        readThroughAtOpen = await readThrough?()
        if let previewsAllowed { previewsHidden = await !previewsAllowed() }
        landed = false
        receiptsWait = initialEvent != nil
        isFocused = false
        openingPages = 0
        landingRow = nil
        unreadMarkerID = nil
        isAtBottom = true
        newSinceDetached = 0
        trackedTailID = nil
        let statuses = await coordinator.statuses()
        observation = Task { [weak self] in
            for await status in statuses { self?.apply(status) }
        }
        await coordinator.open()
        pinnedEventIDs = await coordinator.pinnedEventIDs()
        await draftRestored.value
        clearMarkedUnreadIfVisible()
    }

    /// Opens the timeline before its screen exists (M19-9, D-MOT-2): the screen pushed later shows rows on its first frame. Until
    /// `present()` the model reports nothing about what was read; the draft is only read, never written.
    public func startAhead() async {
        guard observation == nil, starting == nil else { return }
        if !wasPresented { isPresented = false }
        await start()
    }

    /// The screen of a model started ahead is shown: from now on it is an opened room. It lands at the newest row (D95), and
    /// what may have changed while it waited (the read position, the preview setting) is read again.
    public func present() {
        wasPresented = true
        guard !isPresented else { return }
        isPresented = true
        let presented = onPresented
        onPresented = nil
        presented?()
        if landed, !isFocused, let newest = lastRowID {
            landingRow = newest
            trackedTailID = newest
            isAtBottom = true
            newSinceDetached = 0
        }
        if !isFocused { reportOwnMessage(lastItems) }
        reevaluateSeen()
        clearMarkedUnreadIfVisible()
        Task { [weak self] in await self?.refreshAfterPresenting() }
    }

    private func refreshAfterPresenting() async {
        let position = await readThrough?()
        readThroughAtOpen = position
        if landed, !isFocused { unreadMarkerID = Self.firstUnreadItemID(lastItems, readThrough: position) }
        if let previewsAllowed { previewsHidden = await !previewsAllowed() }
    }

    func restoreDraft() async {
        guard let drafts, let room else { return }
        let text = await drafts.draft(for: room)
        guard draft.isEmpty, editing == nil, !text.isEmpty else { return }
        isRestoringDraft = true
        draft = text
        isRestoringDraft = false
    }

    func saveDraft() {
        guard let drafts, let room else { return }
        let text = draft
        Task { await drafts.save(text, for: room) }
    }

    /// Closes the timeline. Call when the screen disappears.
    public func stop() async {
        cancelOpenFile()
        observation?.cancel()
        observation = nil
        clearedMarkedUnread = false
        await coordinator.close()
    }

    /// Retries opening the timeline after a failure.
    public func retry() async {
        await stop()
        await start()
    }

    /// The id of the newest row on screen, or `nil` while there are none.
    public var lastRowID: String? {
        if case .live(let rows, _, _, _) = content { return rows.last?.id }
        return nil
    }

    /// The view has scrolled to the landing row.
    public func landingShown() {
        landingRow = nil
        // Opened at a specific message (Activity → task): go there once the opening scroll is done.
        if let target = initialEvent {
            initialEvent = nil
            Task {
                await jump(toEvent: target)
                reevaluateSeen()
            }
        }
    }

    /// Reports whether the newest row is currently visible (TIMELINE §6: Detached state and "↓ N new" pill).
    public func setAtBottom(_ atBottom: Bool) {
        isAtBottom = atBottom
        if atBottom { reachedBottomWhileFocused() }
        if atBottom {
            newSinceDetached = 0
            trackedTailID = lastRowID
        } else if trackedTailID == nil {
            trackedTailID = lastRowID
        }
    }

    /// The first message from someone else newer than `readThrough` (TIMELINE FR "land at the first unread message"); `nil` when
    /// the read position is unknown or nothing is unread, in which case the timeline stays at the bottom.
    nonisolated static func firstUnreadItemID(_ items: [TimelineItem], readThrough: Date?) -> String? {
        guard let readThrough else { return nil }
        for item in items {
            guard case .event(let event) = item.content, !event.isOwn, event.timestamp > readThrough else { continue }
            switch event.kind {
            case .text, .notice, .emote, .media, .sticker, .location, .poll: return item.id.rawValue
            default: continue
            }
        }
        return nil
    }

    /// How many pages of history a reply jump may load to find its original.
    static let maxJumpPages = 10

    /// Scrolls to the message `row` replies to (TIMELINE FR-8). When it isn't loaded yet, older pages are loaded one at a time
    /// (up to `maxJumpPages`) until it appears. Returns `false` when it wasn't found (deleted, too far back, or the load failed).
    @discardableResult
    public func jumpToReplyOriginal(from row: TimelineRow) async -> Bool {
        guard let target = row.reply?.eventID else { return false }
        return await jump(toEvent: target)
    }

    /// Scrolls to the message with `target` and tints it. When it isn't loaded, the timeline is opened around it (M20-1); where that isn't
    /// possible (a thread, no network) older pages are loaded instead (up to `maxJumpPages`). `false`, with `jumpError`, when it isn't found.
    @discardableResult
    public func jump(toEvent target: EventID) async -> Bool {
        defer { receiptsWait = false }
        if show(target) { return true }
        guard case .live = content else { return false }
        isJumping = true
        defer { isJumping = false }
        do {
            try await coordinator.focus(on: target)
            // Its items reach `content` a moment later.
            for _ in 0..<200 {
                if show(target) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            await coordinator.returnToLive()
            jumpError = "That message can't be shown."
            return false
        } catch {
            if error == .notFound || error == .forbidden {
                jumpError = "That message isn't available any more."
                return false
            }
            if await page(to: target) { return true }
            if case .unsupported = error { return false }
            jumpError = "That message isn't on this device, and the server can't be reached."
            return false
        }
    }

    private func show(_ target: EventID) -> Bool {
        guard case .live(let rows, _, _, _) = content, let row = rows.first(where: { $0.eventID == target }) else { return false }
        jumpRequest = row.id
        highlightedRowID = row.id
        return true
    }

    private func page(to target: EventID) async -> Bool {
        for _ in 0...Self.maxJumpPages {
            if show(target) { return true }
            guard case .live(let rows, _, let canLoadEarlier, _) = content, canLoadEarlier else { return false }
            let before = rows.count
            await loadEarlier()
            // The page's diffs reach `content` a moment after the load returns.
            for _ in 0..<5_000 {
                if case .live(let now, false, _, _) = content, now.count != before { break }
                if case .live(_, false, false, _) = content { break }
                await Task.yield()
            }
        }
        return false
    }

    /// `true` while the timeline shows the messages around an older one; nothing is marked as read then.
    public internal(set) var isFocused = false
    /// A message outside the loaded ones is being looked up.
    public internal(set) var isJumping = false
    /// Why a jump failed, until dismissed.
    public internal(set) var jumpError: String?
    /// Opened at an older message: what is on screen until the jump is done was not chosen by the reader.
    var receiptsWait = false
    var focusReachedEnd = false

    public func dismissJumpError() { jumpError = nil }

    /// Back to the newest messages, landing there like a newly opened room.
    public func returnToNewest() async {
        guard isFocused else { return }
        landed = false
        landingRow = nil
        isAtBottom = true
        newSinceDetached = 0
        await coordinator.returnToLive()
    }

    /// The end of the loaded messages is on screen: newer ones follow, and after the last one the live timeline.
    func reachedBottomWhileFocused() {
        // Not while the list is still being placed at the message that was jumped to.
        guard isFocused, !isJumping, jumpRequest == nil, highlightedRowID == nil else { return }
        let atEnd = focusReachedEnd
        Task { if atEnd { await returnToNewest() } else { await coordinator.paginateForwards() } }
    }

    /// The message to scroll to once the timeline has landed (set by whoever opens the room at a specific event, e.g. Activity).
    public var initialEvent: EventID?

    public func jumpHandled() { jumpRequest = nil }

    public func clearHighlight() { highlightedRowID = nil }


    // MARK: Action & media state
    var readerProfiles: [UserID: (name: String?, avatar: MediaRef?)] = [:]
    var openFileTask: Task<Void, Never>?
    public internal(set) var openedFile: OpenedFile?
    public internal(set) var openingRow: String?
    public internal(set) var openFileError: String?
    public internal(set) var editHistory: EditHistoryState?
    public internal(set) var isSendingImage = false
    public internal(set) var pendingPhotos: [OutgoingImage] = []
    public internal(set) var isSendingFile = false
}
