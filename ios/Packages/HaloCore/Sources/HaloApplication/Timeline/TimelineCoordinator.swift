import HaloDomain
import HaloFoundation

/// Keeps the items of one room's timeline and back-pagination state (docs/features/TIMELINE.md §6).
/// M1 is read-only; sending, receipts and visibility reporting arrive in M2/M3.
public actor TimelineCoordinator {
    public struct Snapshot: Sendable, Equatable {
        public var items: [TimelineItem]
        public var isPaginating: Bool
        /// The start of the room's history has been loaded; pagination does nothing more.
        public var reachedStart: Bool
        /// The last back-pagination failed; shown with a retry button (TIMELINE §9).
        public var paginationError: HaloError?
        /// Other people currently typing.
        public var typing: [UserID]
        /// Members whose identity changed and wasn't accepted (ENCRYPTION_AND_DEVICES FR-7).
        public var identityAlerts: [IdentityAlert] = []
        /// The event the timeline is opened around; `nil` at the newest messages (M20-1).
        public var focus: EventID?
        /// There is nothing newer than the loaded events of a focused timeline.
        public var reachedEnd = false

        public init(items: [TimelineItem], isPaginating: Bool, reachedStart: Bool, paginationError: HaloError?, typing: [UserID] = [], identityAlerts: [IdentityAlert] = []) {
            self.identityAlerts = identityAlerts
            self.typing = typing
            self.items = items
            self.isPaginating = isPaginating
            self.reachedStart = reachedStart
            self.paginationError = paginationError
        }
    }

    public enum Status: Sendable, Equatable {
        case idle
        case opening
        case live(Snapshot)
        /// Opening failed, or the list kept disagreeing with the port's diffs after `maximumResubscriptions` fresh starts.
        case failed(HaloError)
    }

    public static let maximumResubscriptions = 3

    public private(set) var status: Status = .idle {
        didSet { if status != oldValue { broadcaster.publish(status) } }
    }

    private let port: any TimelinePort
    private let room: RoomID
    private let threadRoot: EventID?
    private var broadcaster = SnapshotBroadcaster<Status>()
    private var session: (any TimelineSession)?
    /// The timeline at the newest messages, kept while `session` is a focused one.
    private var liveSession: (any TimelineSession)?
    private var isPaginatingForwards = false
    private var subscription: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var diffsInSubscription = 0
    private var snapshot = Snapshot(items: [], isPaginating: false, reachedStart: false, paginationError: nil)
    private var typingSubscription: Task<Void, Never>?
    private var identitySubscription: Task<Void, Never>?
    private var typingSentAt: ContinuousClock.Instant?
    private let now: @Sendable () -> ContinuousClock.Instant

    /// A typing notice is repeated at most this often while the user keeps typing (MESSAGING FR-4).
    public static let typingInterval: Duration = .seconds(4)

    public init(port: any TimelinePort, room: RoomID, threadRoot: EventID? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.port = port
        self.room = room
        self.threadRoot = threadRoot
        self.now = now
    }

    deinit {
        subscription?.cancel()
        typingSubscription?.cancel()
        identitySubscription?.cancel()
    }

    /// The current status, then its changes; latest value wins (CONCURRENCY §3).
    public func statuses() -> AsyncStream<Status> { broadcaster.subscribe(current: status) }

    public func open() async {
        guard status == .idle else { return }
        status = .opening
        do {
            if let threadRoot {
                session = try await port.openThread(room: room, rootEvent: threadRoot)
            } else {
                session = try await port.open(room: room)
            }
        } catch {
            status = .failed(error)
            return
        }
        consecutiveFailures = 0
        subscribe()
        subscribeTyping()
        subscribeIdentity()
    }

    public func close() async {
        generation += 1
        subscription?.cancel()
        subscription = nil
        typingSubscription?.cancel()
        typingSubscription = nil
        identitySubscription?.cancel()
        identitySubscription = nil
        if typingSentAt != nil { try? await session?.setTyping(false) }
        typingSentAt = nil
        let closing = session, live = liveSession
        session = nil
        liveSession = nil
        snapshot = Snapshot(items: [], isPaginating: false, reachedStart: false, paginationError: nil)
        status = .idle
        await closing?.close()
        await live?.close()
    }

    // MARK: Around an older event (M20-1)

    /// Shows the timeline around `event` instead of its newest messages. On failure what is shown stays. Not for threads.
    public func focus(on event: EventID) async throws(HaloError) {
        guard case .live = status, threadRoot == nil, session != nil else { throw .unsupported("FOCUS") }
        let current = generation
        let focused = try await port.openFocused(room: room, event: event)
        guard current == generation, let session else {
            await focused.close()
            throw .cancelled
        }
        let earlier = liveSession == nil ? nil : session
        if liveSession == nil { liveSession = session }
        self.session = focused
        start(focus: event)
        await earlier?.close()
    }

    /// Back to the newest messages.
    public func returnToLive() async {
        guard let live = liveSession else { return }
        let focused = session
        session = live
        liveSession = nil
        start(focus: nil)
        await focused?.close()
    }

    /// Loads newer events of a focused timeline, once at a time.
    public func paginateForwards() async {
        guard case .live = status, let session, snapshot.focus != nil, !snapshot.reachedEnd, !isPaginatingForwards else { return }
        isPaginatingForwards = true
        defer { isPaginatingForwards = false }
        let current = generation
        guard let reachedEnd = try? await session.paginateForwards(count: 20), current == generation else { return }
        snapshot.reachedEnd = reachedEnd
        publish()
    }

    /// The rows on screen stay until the first items of the new session arrive.
    private func start(focus: EventID?) {
        snapshot = Snapshot(items: [], isPaginating: false, reachedStart: false, paginationError: nil, typing: snapshot.typing, identityAlerts: snapshot.identityAlerts)
        snapshot.focus = focus
        consecutiveFailures = 0
        subscribe()
    }

    /// Sending happens at the newest messages, where the message will be.
    private func sendingSession() async throws(HaloError) -> any TimelineSession {
        await returnToLive()
        guard let session, case .live = status else { throw .cancelled }
        return session
    }

    /// Loads older events once at a time (TIMELINE FR-3). A failure is kept in the snapshot for a retry.
    public func paginateBackwards() async {
        guard case .live = status, let session, !snapshot.isPaginating, !snapshot.reachedStart else { return }
        snapshot.isPaginating = true
        snapshot.paginationError = nil
        publish()
        let current = generation
        do {
            let reachedStart = try await session.paginateBackwards(count: 20)
            guard current == generation else { return }
            snapshot.reachedStart = reachedStart
        } catch {
            guard current == generation else { return }
            snapshot.paginationError = error
        }
        snapshot.isPaginating = false
        publish()
    }

    /// Sends a message into the open timeline; the local echo arrives as a diff. Throws `.cancelled` when the timeline isn't open.
    public func send(_ text: String, mentions: [Mention] = []) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.send(text: text, mentions: mentions)
    }

    /// The user started, kept up or stopped typing. `true` is sent at most every `typingInterval`; `false` goes out at
    /// once, but only if a `true` was sent. Failures are ignored: a missed typing notice isn't worth an error.
    public func setTyping(_ isTyping: Bool) async {
        guard let session, case .live = status else { return }
        if isTyping {
            let instant = now()
            if let last = typingSentAt, instant - last < Self.typingInterval { return }
            typingSentAt = instant
        } else {
            guard typingSentAt != nil else { return }
            typingSentAt = nil
        }
        try? await session.setTyping(isTyping)
    }

    /// Sends a sticker into the open timeline (no local echo: it shows when the server confirms).
    public func sendSticker(_ sticker: Sticker) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.sendSticker(sticker)
    }

    /// Uploads and sends an image into the open timeline; returns when it is sent.
    public func sendImage(_ image: OutgoingImage) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.sendImage(image)
    }

    /// Uploads and sends a file, audio or video clip into the open timeline; returns when it is sent.
    public func sendFile(_ file: OutgoingFile) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.sendFile(file)
    }

    /// Sends a static location into the open timeline (D100).
    public func sendLocation(_ location: OutgoingLocation) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.sendLocation(location)
    }

    /// Starts a poll in the open timeline (D100).
    public func createPoll(_ poll: OutgoingPoll) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.createPoll(poll)
    }

    /// The people who can be mentioned in the open room.
    public func members() async throws(HaloError) -> [RoomMember] {
        guard let session, case .live = status else { throw .cancelled }
        return try await session.members()
    }

    /// Replies to a confirmed event of the open timeline.
    public func reply(to event: EventID, text: String, mentions: [Mention] = []) async throws(HaloError) {
        let session = try await sendingSession()
        try await session.reply(to: event, text: text, mentions: mentions)
    }

    /// Reacts to (or un-reacts from) a confirmed event of the open timeline.
    public func toggleReaction(on event: EventID, key: String) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.toggleReaction(on: event, key: key)
    }

    /// Event IDs currently pinned in the open room.
    public func pinnedEventIDs() async -> [EventID] {
        guard let session else { return [] }
        return await session.pinnedEventIDs()
    }

    /// Pins a confirmed event in the open room (`m.room.pinned_events`).
    public func pin(event: EventID) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.pin(event: event)
    }

    /// Unpins a confirmed event from the open room (`m.room.pinned_events`).
    public func unpin(event: EventID) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.unpin(event: event)
    }

    /// Adds a reaction unless the user already has it; `true` when one was sent.
    @discardableResult
    public func addReaction(on event: EventID, key: String) async throws(HaloError) -> Bool {
        guard let session, case .live = status else { throw .cancelled }
        return try await session.addReaction(on: event, key: key)
    }

    /// Edits the user's own message.
    public func edit(event: EventID, newText: String) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.edit(event: event, newText: newText)
    }

    /// The versions of an edited message, oldest first. Throws `.cancelled` when the timeline isn't open.
    public func editHistory(of event: EventID) async throws(HaloError) -> [EditRevision] {
        guard let session, case .live = status else { throw .cancelled }
        return try await session.editHistory(of: event)
    }

    /// Deletes the user's own message.
    public func delete(event: EventID) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.delete(event: event)
    }

    /// Sends a failed message again.
    public func retrySend(localID: String) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.retrySend(localID: localID)
    }

    /// Deletes a message that was never sent.
    public func abortSend(localID: String) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.abortSend(localID: localID)
    }

    /// The latest event ID in the room's timeline (including non-row events such as poll votes, R-01/R-06).
    public func latestEventID() async -> EventID? {
        guard let session, case .live = status else { return nil }
        return await session.latestEventID()
    }

    // MARK: Private

    private func subscribe() {
        guard let session else { return }
        subscription?.cancel()
        generation += 1
        diffsInSubscription = 0
        snapshot.items = []
        let current = generation
        let diffs = session.items()
        subscription = Task { [weak self] in
            for await diff in diffs {
                guard let self, await self.apply(diff, generation: current) else { return }
            }
        }
    }

    private func subscribeTyping() {
        guard let session else { return }
        let updates = session.typingUsers()
        typingSubscription = Task { [weak self] in
            for await users in updates { await self?.applyTyping(users) }
        }
    }

    private func subscribeIdentity() {
        guard let session else { return }
        let updates = session.identityAlerts()
        identitySubscription = Task { [weak self] in
            for await alerts in updates { await self?.applyIdentity(alerts) }
        }
    }

    private func applyIdentity(_ alerts: [IdentityAlert]) {
        guard session != nil, snapshot.identityAlerts != alerts else { return }
        snapshot.identityAlerts = alerts
        if case .live = status { publish() }
    }

    /// Accepts `user`'s current identity (FR-7). The alert ends when the SDK reports the new state.
    public func acceptIdentity(of user: UserID) async throws(HaloError) {
        guard let session, case .live = status else { throw .cancelled }
        try await session.acceptIdentity(of: user)
    }

    private func applyTyping(_ users: [UserID]) {
        guard session != nil, snapshot.typing != users else { return }
        snapshot.typing = users
        if case .live = status { publish() }
    }

    private func apply(_ diff: TimelineDiff, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        do {
            try ListReducer.apply(diff, to: &snapshot.items)
            diffsInSubscription += 1
            if diffsInSubscription > 1 { consecutiveFailures = 0 }
            publish()
            return true
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures > Self.maximumResubscriptions {
                subscription = nil
                status = .failed(error)
            } else {
                // A fresh subscription starts from a `.reset`, which repairs the list.
                subscribe()
            }
            return false
        }
    }

    /// The room's first event is loaded once the SDK has put its `timelineStart` marker on top; that is the
    /// authoritative signal (the SDK's pagination result can still say "more" for one more call).
    private func publish() {
        if snapshot.items.first?.content == .virtual(.timelineStart) { snapshot.reachedStart = true }
        status = .live(snapshot)
    }
}
