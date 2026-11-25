import Foundation
import HaloDomain
import HaloFoundation

/// What came of Reply or Mark as read on a notification.
public enum NotificationActionOutcome: Equatable, Sendable {
    /// The server has it.
    case done
    /// Reply only: queued in the send queue; it goes out when Halo connects (survives a kill).
    case queued
    /// It didn't happen, and the person is told (a reply is kept as a draft when it can be).
    case failed
    /// The same notification's same action ran already: nothing is done twice.
    case duplicate
}

/// Reply and Mark as read from the lock screen (NOTIFICATIONS FR-10, M18-7, AC-REL-7). iOS can launch Halo in the background
/// for these with nothing running, so the work waits for the session, and runs once per notification and action.
public actor NotificationActionCoordinator {
    private let send: @Sendable (_ text: String, _ room: RoomID) async throws(HaloError) -> SiriSendOutcome
    private let markRead: @Sendable (_ room: RoomID, _ latestEventTime: Date) async throws(HaloError) -> Void
    private let keepDraft: @Sendable (_ text: String, _ room: RoomID) async -> Void
    private var handled: Set<String> = []

    public init(
        send: @escaping @Sendable (_ text: String, _ room: RoomID) async throws(HaloError) -> SiriSendOutcome,
        markRead: @escaping @Sendable (_ room: RoomID, _ latestEventTime: Date) async throws(HaloError) -> Void,
        keepDraft: @escaping @Sendable (_ text: String, _ room: RoomID) async -> Void
    ) {
        self.send = send
        self.markRead = markRead
        self.keepDraft = keepDraft
    }

    /// Sends the text typed into the notification. A failure keeps the text as the room's draft, so nothing typed is lost.
    public func reply(text: String, to room: RoomID, notification: String) async -> NotificationActionOutcome {
        guard handled.insert("reply:\(notification)").inserted else { return .duplicate }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }
        do {
            return try await send(trimmed, room) == .confirmed ? .done : .queued
        } catch {
            await keepDraft(trimmed, room)
            return .failed
        }
    }

    /// Reads the room up to its newest event (as "Mark as read" in the room list does).
    public func markRead(room: RoomID, at time: Date, notification: String) async -> NotificationActionOutcome {
        guard handled.insert("read:\(notification)").inserted else { return .duplicate }
        do {
            try await markRead(room, time)
            return .done
        } catch {
            return .failed
        }
    }
}
