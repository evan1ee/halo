import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `TimelinePort` over the SDK `Timeline` (SDK_INTEGRATION §6). Each session owns its upstream
/// subscriptions and cancels them when its stream ends or it is closed (AGENTS.md §8).
public final class MatrixTimelinePort: TimelinePort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func open(room id: RoomID) async throws(HaloError) -> any TimelineSession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        do { return MatrixTimelineSession(room: room, timeline: try await room.timeline(), ownUserID: own) } catch { throw ErrorMapper.map(error) }
    }
}

final class MatrixTimelineSession: TimelineSession {
    private let room: Room
    private let timeline: Timeline
    private let ownUserID: String

    init(room: Room, timeline: Timeline, ownUserID: String) {
        self.room = room
        self.timeline = timeline
        self.ownUserID = ownUserID
    }

    func items() -> AsyncStream<HaloDomain.TimelineDiff> {
        let (output, continuation) = AsyncStream<HaloDomain.TimelineDiff>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [timeline, ownUserID] in
            let (raw, rawContinuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: Listener(rawContinuation))
            defer { handle.cancel() }
            for await batch in raw {
                for update in batch { continuation.yield(TimelineMapper.map(update, ownUserID: ownUserID)) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return output
    }

    func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool {
        do { return try await timeline.paginateBackwards(numEvents: count) } catch { throw ErrorMapper.map(error) }
    }

    func send(text: String) async throws(HaloError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do {
            // Markdown is converted to the message content (formatted body) by the SDK. The returned handle (to abort
            // a queued send) isn't needed yet; failed sends are retried by the send queue.
            _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
        } catch { throw ErrorMapper.map(error) }
    }

    func typingUsers() -> AsyncStream<[UserID]> {
        let (output, continuation) = AsyncStream<[UserID]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = room.subscribeToTypingNotifications(listener: TypingListener(own: ownUserID, continuation: continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return output
    }

    func setTyping(_ isTyping: Bool) async throws(HaloError) {
        do { try await room.typingNotice(isTyping: isTyping) } catch { throw ErrorMapper.map(error) }
    }

    func reply(to event: EventID, text: String) async throws(HaloError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do { _ = try await timeline.sendReply(msg: messageEventContentFromMarkdown(md: text), eventId: event.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    func toggleReaction(on event: EventID, key: String) async throws(HaloError) {
        do { _ = try await timeline.toggleReaction(itemId: .eventId(eventId: event.rawValue), key: key) } catch { throw ErrorMapper.map(error) }
    }

    func edit(event: EventID, newText: String) async throws(HaloError) {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do {
            try await timeline.edit(
                eventOrTransactionId: .eventId(eventId: event.rawValue),
                newContent: .roomMessage(content: messageEventContentFromMarkdown(md: newText)))
        } catch { throw ErrorMapper.map(error) }
    }

    func delete(event: EventID) async throws(HaloError) {
        do { try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: event.rawValue), reason: nil) } catch { throw ErrorMapper.map(error) }
    }

    func retrySend(localID: String) async throws(HaloError) {
        do { guard try await timeline.retrySend(itemId: .transactionId(transactionId: localID), target: .event) else { throw HaloError.notFound } } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    func abortSend(localID: String) async throws(HaloError) {
        do { guard try await timeline.abortSend(itemId: .transactionId(transactionId: localID), target: .event) else { throw HaloError.notFound } } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    func close() async {}
}

private final class Listener: TimelineListener {
    private let continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation
    init(_ continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation) { self.continuation = continuation }
    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) { continuation.yield(diff) }
}

/// Forwards the SDK's typing set, without the signed-in user.
private final class TypingListener: TypingNotificationsListener {
    let own: String
    let continuation: AsyncStream<[UserID]>.Continuation
    init(own: String, continuation: AsyncStream<[UserID]>.Continuation) {
        self.own = own
        self.continuation = continuation
    }

    func call(typingUserIds: [String]) {
        continuation.yield(typingUserIds.filter { $0 != own }.compactMap { try? UserID($0) })
    }
}
