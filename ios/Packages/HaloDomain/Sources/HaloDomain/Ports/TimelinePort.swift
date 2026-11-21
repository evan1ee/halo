import HaloFoundation

/// Opens the timeline of one room (docs/matrix/PORTS_CONTRACT.md §2). Implemented by
/// `HaloMatrixAdapter`; faked in `HaloTestSupport`. Reading since M1; plain-text sending since M2.
public protocol TimelinePort: Sendable {
    /// Opens `room`'s timeline. Throws `.notFound` if the client doesn't know the room.
    func open(room: RoomID) async throws(HaloError) -> any TimelineSession

    /// Prepares the timelines of the rooms the user is most likely to open next (the top of the room list), so opening one
    /// shows its messages at once. Best effort: failures are ignored. Ports with nothing to prepare keep the default.
    func warm(_ rooms: [RoomID]) async

    /// Lets go of everything `warm` prepared (sign-out).
    func dropWarm() async
}

extension TimelineSession {
    public func addReaction(on event: EventID, key: String) async throws(HaloError) -> Bool { throw .unsupported("ADD_REACTION") }
    public func editHistory(of event: EventID) async throws(HaloError) -> [EditRevision] { throw .unsupported("EDIT_HISTORY") }
}

extension TimelinePort {
    public func warm(_ rooms: [RoomID]) async {}
    public func dropWarm() async {}
}

/// One open timeline. Closing (or dropping) it cancels every upstream subscription.
public protocol TimelineSession: Sendable {
    /// The timeline as lossless, ordered diffs (apply with `ListReducer`). The first element is a `.reset`
    /// or an `.append` onto an empty list; a new call starts over from such a state.
    func items() -> AsyncStream<TimelineDiff>

    /// Loads up to `count` older events. Returns `true` when the start of the room has been reached.
    func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool

    /// The people who can be mentioned: joined members of the room. Throws on failure.
    func members() async throws(HaloError) -> [RoomMember]

    /// Sends a plain-text or Markdown message. `mentions` are users named as `@name` in `text`; those still in the text become
    /// links in the formatted body and go into `m.mentions` (see `MentionFormatter`). It appears in `items()` at once as `.sending` (local echo) and turns
    /// `.sent` when the server confirms. Throws `.invalidInput("EMPTY_MESSAGE")` for blank text.
    func send(text: String, mentions: [Mention]) async throws(HaloError)

    /// Who else is typing in the room, as the current set and then every change (latest value wins). Never contains
    /// the signed-in user.
    func typingUsers() -> AsyncStream<[UserID]>

    /// Tells the room the signed-in user is (or has stopped) typing. Callers throttle; the server expires a notice itself.
    func setTyping(_ isTyping: Bool) async throws(HaloError)

    /// Sends `text` as a reply to the confirmed event `event`. Same local-echo and error rules as `send(text:)`;
    /// an unknown event throws `.notFound`.
    func reply(to event: EventID, text: String, mentions: [Mention]) async throws(HaloError)

    /// Adds the signed-in user's reaction `key` to a confirmed event, or removes it if already there. Events that
    /// are still sending have no event ID yet and can't be reacted to.
    func toggleReaction(on event: EventID, key: String) async throws(HaloError)

    /// Adds the signed-in user's reaction `key` to a confirmed event only if they haven't reacted with it yet (unlike
    /// `toggleReaction`, never removes one). Returns `true` when a reaction was sent. Works for events that aren't in the loaded
    /// window. Sessions that can't tell throw `.unsupported`.
    func addReaction(on event: EventID, key: String) async throws(HaloError) -> Bool

    /// Replaces the text of the user's own message. Blank text throws `.invalidInput("EMPTY_MESSAGE")`; someone
    /// else's message throws `.forbidden`.
    func edit(event: EventID, newText: String) async throws(HaloError)

    /// The versions of an edited message, oldest first (TIMELINE FR-9). Sessions that can't tell throw `.unsupported`.
    func editHistory(of event: EventID) async throws(HaloError) -> [EditRevision]

    /// Deletes (redacts) the user's own message.
    func delete(event: EventID) async throws(HaloError)

    /// Sends `sticker` as an `m.sticker` event. It is sent at once and has no local echo: it appears when the server confirms it, and a network failure throws (offline sending is not supported for stickers).
    func sendSticker(_ sticker: Sticker) async throws(HaloError)

    /// Uploads and sends `image` as an `m.image`. It appears as a local echo while uploading. Returns when the server has the
    /// message or throws. `.invalidInput` for an invalid image (see `OutgoingImage.validate`).
    func sendImage(_ image: OutgoingImage) async throws(HaloError)
    /// Uploads a file, audio or video clip unchanged and sends it as `m.file`, `m.audio` or `m.video`; returns when it is sent.
    /// `.invalidInput` for an invalid file (see `OutgoingFile.validate`).
    func sendFile(_ file: OutgoingFile) async throws(HaloError)

    /// Sends a failed local echo again (`TimelineEvent.localID`). Throws `.notFound` if the echo is gone (it was sent or deleted meanwhile).
    func retrySend(localID: String) async throws(HaloError)

    /// Deletes a local echo that hasn't been sent (or is failed), so it is never sent. Throws `.notFound` if it already went out.
    func abortSend(localID: String) async throws(HaloError)

    func close() async
}

extension TimelineSession {
    public func send(text: String) async throws(HaloError) { try await send(text: text, mentions: []) }
    public func reply(to event: EventID, text: String) async throws(HaloError) { try await reply(to: event, text: text, mentions: []) }
}
