import Foundation
import HaloDomain
import HaloFoundation

/// Outcome of a Siri / Shortcuts send (M16, builds on D88).
public enum SiriSendOutcome: Equatable, Sendable {
    /// The server echoed the message within the confirmation window.
    case confirmed
    /// Handed to the timeline send queue; will finish sending when Halo connects.
    case queued
}

/// Sends one plain-text message on behalf of Siri or Shortcuts (M16, builds on D88).
/// Restores the stored session if Siri woke Halo in the background, sends through the normal timeline path,
/// and waits briefly for server confirmation so Siri can speak honestly (AGENTS.md §4.4).
public actor SiriSendCoordinator {
    private let session: SessionCoordinator
    private let timelines: any TimelinePort
    private let confirmLimit: Duration

    public init(
        session: SessionCoordinator,
        timelines: any TimelinePort,
        confirmLimit: Duration = .seconds(15)
    ) {
        self.session = session
        self.timelines = timelines
        self.confirmLimit = confirmLimit
    }

    public func send(text: String, to room: RoomID) async throws(HaloError) -> SiriSendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("SIRI_EMPTY_MESSAGE") }

        switch await session.state {
        case .ready:
            break
        case .launching:
            await session.start()
        case .restoreFailed:
            await session.retryRestore()
        default:
            break
        }
        guard case .ready = await session.state else { throw .unauthorized(soft: false) }

        let timeline = try await timelines.open(room: room)
        let stream = timeline.items()
        let watcher = Task { await Self.watch(stream, limit: confirmLimit) }
        do {
            try await timeline.send(text: trimmed)
        } catch {
            watcher.cancel()
            await timeline.close()
            throw error
        }
        let state = await watcher.value
        await timeline.close()
        switch state {
        case .confirmed: return .confirmed
        case .failed: throw .network(retryable: true)
        case .waiting: return .queued
        }
    }

    private static func watch(_ stream: AsyncStream<TimelineDiff>, limit: Duration) async -> SendConfirmation.State {
        await withTaskGroup(of: SendConfirmation.State.self) { group in
            group.addTask {
                var tracker = SendConfirmation(expected: 1)
                for await diff in stream {
                    tracker.apply(diff)
                    if tracker.state != .waiting { return tracker.state }
                }
                return .waiting
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .waiting
            }
            let first = await group.next() ?? .waiting
            group.cancelAll()
            return first
        }
    }
}
