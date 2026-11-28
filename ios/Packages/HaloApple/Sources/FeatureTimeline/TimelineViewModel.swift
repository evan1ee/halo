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

    /// Owned child models (audit F-08): bot tasks, composer state, and media playback/downloads.
    public let botState = TimelineBotTaskModel()
    public let composer = TimelineComposerModel()
    public let mediaState: TimelineMediaModel

    /// User IDs of bots whose messages may become cards (Settings → Bots, BOT_MESSAGES §3).
    public var botSenders: Set<String> {
        get { botState.botSenders }
        set { botState.botSenders = newValue }
    }
    /// Reports a known bot's message whose formatted body no template recognised (by event ID; for the diagnostics count).
    public var unrecognisedBotMessages: UnrecognisedBotMessages? {
        get { botState.unrecognisedBotMessages }
        set { botState.unrecognisedBotMessages = newValue }
    }
    /// Receives every snapshot of this room so the Activity index learns the bots' tasks (BOT_ACTIVITY FR-1).
    public var botActivity: BotActivityCoordinator? {
        get { botState.botActivity }
        set { botState.botActivity = newValue }
    }
    /// What the room's bot messages say about tasks (BOT_MESSAGES §6); recomputed with every snapshot.
    public var botTasks: BotTaskTracker { botState.tasks }
    var botTapped: Set<BotTaskTracker.Key> {
        get { botState.tapped }
        set { botState.tapped = newValue }
    }
    var botUnanswered: Set<BotTaskTracker.Key> {
        get { botState.unanswered }
        set { botState.unanswered = newValue }
    }
    var botTimeout: Duration {
        get { botState.timeout }
        set { botState.timeout = newValue }
    }

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
        botState.rowState(bot: bot, id: id)
    }

    /// Ticks a row: one 👍 on the message that created the task, never on the list (BOT_MESSAGES FR-3). Ignored while pending,
    /// done or unavailable, and no second 👍 is sent when the user already has one on that message.
    public func tickBotTask(bot: String?, id: String) async {
        let rows: [TimelineRow] = if case .live(let current, _, _, _) = content { current } else { [] }
        await botState.tick(
            bot: bot,
            id: id,
            rows: rows,
            toggleReaction: { [coordinator] eventID, key in try await coordinator.toggleReaction(on: eventID, key: key) },
            onError: { [composer] message in composer.sendError = message }
        )
    }

    func botTimedOut(_ key: BotTaskTracker.Key) { botState.timedOut(key) }

    /// Whether typing notices are sent while the user composes (Settings → Privacy → Typing notices, SETTINGS §3).
    public var sendsTypingNotices: @MainActor () -> Bool = { true }
    /// KLIPY GIFs and stickers (D98); `nil` hides them, and KLIPY links then show as plain links.
    public var klipy: KlipyCatalog?

    /// The Article editor's text (D101): kept while the editor is closed, cleared once the article was sent.
    public var articleDraft: String {
        get { composer.articleDraft }
        set { composer.articleDraft = newValue }
    }

    /// The message being typed. Cleared only once the send was accepted, so a failure never loses the text.
    public var draft: String {
        get { composer.draft }
        set { composer.draft = newValue }
    }

    /// People that can be mentioned in this room; loaded the first time the user types `@`.
    public var members: [RoomMember] {
        get { composer.members }
        set { composer.members = newValue }
    }
    var pendingMentions: [Mention] {
        get { composer.pendingMentions }
        set { composer.pendingMentions = newValue }
    }

    public var mentionQuery: String? { composer.mentionQuery }
    public var mentionSuggestions: [RoomMember] { composer.mentionSuggestions }
    public func pickMention(_ member: RoomMember) { composer.pickMention(member) }

    func loadMembersIfNeeded() {
        guard !composer.membersRequested else { return }
        composer.membersRequested = true
        Task {
            if let loaded = try? await coordinator.members() { composer.members = loaded } else { composer.membersRequested = false }  // best-effort: a read or a cache; a miss changes nothing the person sees
        }
    }

    public var emojiSuggestions: [NativeEmoji.Entry] { composer.emojiSuggestions }
    public func pickEmojiSuggestion(_ entry: NativeEmoji.Entry) { composer.pickEmojiSuggestion(entry) }
    public func insertEmoji(_ emoji: String) { composer.insertEmoji(emoji) }
    public var recentEmoji: [String] { composer.recentEmoji }
    func recordRecentEmoji(_ emoji: String) { composer.recordRecentEmoji(emoji) }

    /// "Alice is typing…", or `nil` when nobody else is.
    public internal(set) var typingText: String?
    /// Contacts whose identity changed and wasn't accepted yet, shown above the composer until handled (FR-7, AC-SEC-1).
    public internal(set) var identityNotices: [IdentityNotice] = []
    /// Names of the loaded timeline's senders, for the reasons a send was refused.
    var senderNames: [UserID: String] = [:]
    public var isSending: Bool {
        get { composer.isSending }
        set { composer.isSending = newValue }
    }
    public var sendError: String? {
        get { composer.sendError }
        set { composer.sendError = newValue }
    }
    /// Double-tap protection for changes to messages (AC-REL-4).
    let actions = ActionGuard()
    /// The own message being edited, or `nil` when the composer writes a new message.
    public var editing: EventID? {
        get { composer.editing }
        set { composer.editing = newValue }
    }
    /// The message an emoji is being picked for, or `nil` when the picker is closed.
    public var reactionTarget: TimelineRow? {
        get { composer.reactionTarget }
        set { composer.reactionTarget = newValue }
    }
    /// The emoji offered by the picker (a fixed set; the quick row of the menu is `quickReactions`).
    public static let quickReactions = ["👍", "❤️", "😂"]
    public static let pickerEmoji = [
        "👍", "👎", "❤️", "😂", "😮", "😢", "😡", "🎉", "🙏", "👏", "🔥", "💯", "✅", "❌", "👀", "🤔",
        "😀", "😅", "😉", "😍", "😘", "😎", "🥳", "😴", "🤯", "😬", "🙄", "🤗", "😇", "🤝", "💪", "🙌",
        "👋", "✌️", "👌", "🤞", "🫡", "🫶", "💔", "💙", "💚", "⭐️", "✨", "🚀", "☕️", "🍕", "🎂", "🌈",
    ]
    /// The message the next send replies to, or `nil`.
    public var replyingTo: TimelineRow? {
        get { composer.replyingTo }
        set { composer.replyingTo = newValue }
    }

    public var canSend: Bool { composer.canSend }

    let coordinator: TimelineCoordinator
    let media: MediaLoader?
    /// Owns inline playback of voice messages and audio files for this room so playback survives scrolling (MEDIA_ATTACHMENTS FR-3, M20-2).
    public var audioPlayer: AudioPlaybackController { mediaState.audioPlayer }
    let previewsAllowed: (@Sendable () async -> Bool)?
    /// `true` when the account's media preview setting asks for a tap before photos in this room are shown (FR-7).
    public var previewsHidden: Bool {
        get { mediaState.previewsHidden }
        set { mediaState.previewsHidden = newValue }
    }
    var thumbnailMemory: TimelineThumbnailMemory { mediaState.thumbnailMemory }
    var knownPhotoRefs: [String: MediaRef] {
        get { mediaState.knownPhotoRefs }
        set { mediaState.knownPhotoRefs = newValue }
    }
    /// The row made for each item the last time, reused while the item and its narrow external dependencies
    /// (calendar day for dividers, bot membership for that sender, profiles for its readers, names for its send failure)
    /// are unchanged (M19-2, audit P-5): a new member speaking maps one row, not the whole room.
    struct RowCacheEntry {
        let item: TimelineItem
        let context: Int
        let row: TimelineRow
    }
    var rowCache: [TimelineItemID: RowCacheEntry] = [:]
    /// How many rows `row(_:)` made through `buildRows`; the test that pins M19-2 / audit P-5 reads it.
    var rowsMapped = 0
    var observation: Task<Void, Never>?
    let dateFormatter: DateFormatter
    let timeFormatter: DateFormatter
    let editTimeFormatter: DateFormatter
    let infoTimeFormatter: DateFormatter
    let receipts: ReadReceiptCoordinator?
    let drafts: DraftCoordinator?
    let imagePreparer: (any ImagePreparing)?
    let videoPreparer: (any VideoPreparing)?
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
    /// The row currently being forwarded in `ForwardSheet`, if any (MESSAGING FR-8, M20-6).
    public private(set) var forwardingRow: TimelineRow?
    /// Executes multi-target message forwarding (injected by composition root, M20-6).
    public var forwarder: ForwardCoordinator?
    /// Loads the room encryption state and joined destination chats for `ForwardSheet`.
    public var loadForwardTargets: (@Sendable () async -> (sourceIsEncrypted: Bool, targets: [ForwardTarget]))?
    /// Whether forwarding is available in this timeline.
    public var canForward: Bool { forwarder != nil && loadForwardTargets != nil }

    public func beginForward(_ row: TimelineRow) {
        guard row.canForward, canForward else { return }
        forwardingRow = row
    }

    public func cancelForward() {
        forwardingRow = nil
    }

    public func makeForwardViewModel(for row: TimelineRow) -> ForwardViewModel? {
        guard let payload = row.forwardPayload, let forwarder, let loadForwardTargets else { return nil }
        return ForwardViewModel(payload: payload, forwarder: forwarder, loadTargets: loadForwardTargets)
    }

    /// Lifecycle state when the room is upgraded (tombstoned), left, banned, or pending knock (GA-23, M20-8).
    public private(set) var lifecycleBanner: RoomBannerState?
    public private(set) var isActingOnLifecycle = false
    public private(set) var lifecycleError: String?
    public private(set) var lifecycleClosedRoom = false
    /// Whether this room is end-to-end encrypted, for Message Info (M20-9); `nil` while unknown.
    public private(set) var isRoomEncrypted: Bool?
    /// Queries current room lifecycle state (`membership`, `successor`); injected by composition root.
    public var loadRoomLifecycle: (@Sendable () async -> RoomBannerState?)?
    /// Queries whether this room is encrypted; injected by composition root (M20-9).
    public var loadRoomEncrypted: (@Sendable () async -> Bool?)?
    /// Leaves and forgets the current room (e.g. an upgraded room).
    public var leaveAndForgetRoom: (@Sendable () async throws(HaloError) -> Void)?
    /// Forgets the current left or banned room.
    public var forgetCurrentRoom: (@Sendable () async throws(HaloError) -> Void)?
    /// Cancels a pending knock request in the current room.
    public var cancelCurrentKnock: (@Sendable () async throws(HaloError) -> Void)?

    public func refreshLifecycle() async {
        if let loadRoomEncrypted {
            let encrypted = await loadRoomEncrypted()
            if isRoomEncrypted != encrypted {
                isRoomEncrypted = encrypted
            }
        }
        guard let loadRoomLifecycle else { return }
        let updated = await loadRoomLifecycle()
        if lifecycleBanner != updated {
            lifecycleBanner = updated
        }
    }

    public func runLeaveAndForget() async {
        guard let leaveAndForgetRoom, !isActingOnLifecycle else { return }
        await runLifecycleAction(verb: "leave this room", leaveAndForgetRoom)
    }

    public func runForgetRoom() async {
        guard let forgetCurrentRoom, !isActingOnLifecycle else { return }
        await runLifecycleAction(verb: "forget this room", forgetCurrentRoom)
    }

    public func runCancelKnock() async {
        guard let cancelCurrentKnock, !isActingOnLifecycle else { return }
        await runLifecycleAction(verb: "cancel your request", cancelCurrentKnock)
    }

    private func runLifecycleAction(verb: String, _ work: @Sendable () async throws(HaloError) -> Void) async {
        isActingOnLifecycle = true
        lifecycleError = nil
        defer { isActingOnLifecycle = false }
        do {
            try await work()
            lifecycleClosedRoom = true
        } catch {
            lifecycleError = error == .network(retryable: true)
                ? "You appear to be offline. Try again."
                : "Couldn't \(verb). Try again."
        }
    }

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
        drafts: DraftCoordinator? = nil, images: (any ImagePreparing)? = nil, videos: (any VideoPreparing)? = nil, readThrough: (@Sendable () async -> Date?)? = nil, dwell: Duration = TimelineViewModel.seenDwell, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        locale: Locale = .current, timeZone: TimeZone = .current, thumbnails: TimelineThumbnailMemory? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        audioPlayer: AudioPlaybackController? = nil
    ) {
        self.coordinator = coordinator
        self.mediaState = TimelineMediaModel(media: media, thumbnails: thumbnails, audioPlayer: audioPlayer)
        self.media = media
        self.previewsAllowed = previewsAllowed
        self.receipts = receipts
        self.room = room
        self.drafts = drafts
        self.imagePreparer = images
        self.videoPreparer = videos
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
        let info = DateFormatter()
        info.locale = time.locale
        info.timeZone = time.timeZone
        info.dateStyle = .medium
        info.timeStyle = .medium
        infoTimeFormatter = info
        composer.onDraftEdited = { [weak self] text, hasMention in
            guard let self else { return }
            self.saveDraft()
            if hasMention { self.loadMembersIfNeeded() }
            let isTyping = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if self.sendsTypingNotices() {
                Task { [coordinator = self.coordinator] in await coordinator.setTyping(isTyping) }
            } else if !isTyping {
                // If disabled mid-draft, still clear any typing notice already sent; no-op when none was sent.
                Task { [coordinator = self.coordinator] in await coordinator.setTyping(false) }
            }
        }
    }

    /// Exact date and time with seconds for Message Info and read-receipt timestamps (M20-9).
    public func formatInfoTimestamp(_ date: Date) -> String {
        infoTimeFormatter.string(from: date)
    }

    isolated deinit {
        observation?.cancel()
        dwellTask?.cancel()
        botState.cancelTimeouts()
    }

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
        // A `stop()` that came while this was waiting cancels the start: nothing is followed or opened for a closed screen.
        guard !Task.isCancelled else { return await draftRestored.value }
        let statuses = await coordinator.statuses()
        guard !Task.isCancelled else { return await draftRestored.value }
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
        composer.applyRestoredDraft(text)
    }

    func saveDraft() {
        guard let drafts, let room else { return }
        let text = draft
        Task { await drafts.save(text, for: room) }
    }

    /// Closes the timeline. Call when the screen disappears. A start still under way is cancelled and waited for first, so it
    /// can't open the timeline again after this closed it (audit F-10).
    public func stop() async {
        if let starting {
            starting.cancel()
            await starting.value
        }
        botState.cancelTimeouts()
        mediaState.stop()
        removePendingVideos()
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


    // MARK: Action & media state (forwarded to owned child models; poll/edit state stays here)
    var readerProfiles: [UserID: (name: String?, avatar: MediaRef?)] = [:]
    public var openedFile: OpenedFile? { mediaState.openedFile }
    public var openingRow: String? { mediaState.openingRow }
    public var openedVideo: OpenedVideo? { mediaState.openedVideo }
    public var openingVideoRow: String? { mediaState.openingVideoRow }
    public var openFileError: String? { mediaState.openFileError }
    public internal(set) var editHistory: EditHistoryState?
    public var isSendingImage: Bool {
        get { composer.isSendingImage }
        set { composer.isSendingImage = newValue }
    }
    public var pendingPhotos: [OutgoingImage] {
        get { composer.pendingPhotos }
        set { composer.pendingPhotos = newValue }
    }
    public var isSendingVideo: Bool {
        get { composer.isSendingVideo }
        set { composer.isSendingVideo = newValue }
    }
    public var pendingVideos: [OutgoingFile] {
        get { composer.pendingVideos }
        set { composer.pendingVideos = newValue }
    }
    public var isSendingFile: Bool {
        get { composer.isSendingFile }
        set { composer.isSendingFile = newValue }
    }
    /// Poll votes sent by this device and waiting for the server echo (AC-M5, M20-4).
    public internal(set) var pendingPollVotes: [EventID: [String]] = [:]
    /// Own polls whose `m.poll.end` is waiting for server confirmation (M20-4).
    public internal(set) var endingPolls: Set<EventID> = []
    /// Per-poll inline error message when a vote or end fails (M20-4).
    public internal(set) var pollErrors: [EventID: String] = [:]
}
