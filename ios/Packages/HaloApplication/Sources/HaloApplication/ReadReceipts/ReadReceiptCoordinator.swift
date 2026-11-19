import Foundation
import HaloDomain
import HaloFoundation

/// Turns "the user has seen this event" into read receipts (docs/matrix/READ_RECEIPTS.md §1): ignores candidates that
/// don't advance the read position, keeps only the newest intent per room, sends at most one receipt per room per
/// `minimumInterval`, and retries retryable failures with backoff. The caller decides *what is visible* (D6: ≥ 50 %
/// for ≥ 0.5 s, app active, room on top); this actor never looks at views.
/// Intents live in memory only: persisting `read_intent` comes with the M3 unread persistence.
public actor ReadReceiptCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let minimumInterval: Duration = .seconds(2)
    public static let initialBackoff: Duration = .seconds(1)
    public static let maximumBackoff: Duration = .seconds(300)

    private struct Intent {
        var event: EventID
        var timestamp: Date
        var sent: Bool
    }

    private let port: any ReadMarkerPort
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: Sleep
    private var isPrivate: Bool
    private var intents: [RoomID: Intent] = [:]
    private var lastSend: [RoomID: ContinuousClock.Instant] = [:]
    private var failures: [RoomID: Int] = [:]
    private var scheduled: [RoomID: Task<Void, Never>] = [:]

    public init(
        port: any ReadMarkerPort, privateReceipts: Bool = false,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.isPrivate = privateReceipts
        self.now = now
        self.sleep = sleep
    }

    deinit { for task in scheduled.values { task.cancel() } }

    /// The privacy setting (D7); applies to receipts sent from now on.
    public func setPrivateReceipts(_ value: Bool) { isPrivate = value }

    /// The time of the newest event the user has read in `room` through this coordinator, if any.
    public func readPosition(of room: RoomID) -> Date? { intents[room]?.timestamp }

    /// The newest event the user has seen in `room`. Local echoes have no event ID and must not be reported.
    /// Candidates not newer than the current intent are ignored.
    public func reportSeen(room: RoomID, event: EventID, timestamp: Date) {
        if let current = intents[room], timestamp <= current.timestamp { return }
        intents[room] = Intent(event: event, timestamp: timestamp, sent: false)
        failures[room] = nil
        schedule(room, after: dueIn(room))
    }

    /// Sends every unsent intent now (foreground, reconnect, background flush); backoff is bypassed.
    public func flush() async {
        for room in intents.keys where intents[room]?.sent == false {
            scheduled[room]?.cancel()
            scheduled[room] = nil
            await send(room)
        }
    }

    // MARK: -

    private func dueIn(_ room: RoomID) -> Duration {
        guard let last = lastSend[room] else { return .zero }
        let elapsed = last.duration(to: now())
        return elapsed >= Self.minimumInterval ? .zero : Self.minimumInterval - elapsed
    }

    private func schedule(_ room: RoomID, after delay: Duration) {
        scheduled[room]?.cancel()
        scheduled[room] = Task { [weak self, sleep] in
            if delay > .zero { do { try await sleep(delay) } catch { return } }
            await self?.send(room)
        }
    }

    private func send(_ room: RoomID) async {
        guard let intent = intents[room], !intent.sent else { return }
        scheduled[room] = nil
        lastSend[room] = now()
        do {
            try await port.sendReceipt(room: room, event: intent.event, isPrivate: isPrivate)
            // A newer intent may have arrived while sending; only mark ours.
            if intents[room]?.event == intent.event { intents[room]?.sent = true }
            failures[room] = nil
            do { try await port.setFullyRead(room: room, event: intent.event) } catch {
                // The receipt is what counts; the marker follows with the next intent.
            }
            if let newer = intents[room], !newer.sent { schedule(room, after: dueIn(room)) }
        } catch {
            guard error.isRetryable else { return }
            let attempt = failures[room, default: 0]
            failures[room] = attempt + 1
            let backoff = min(Self.initialBackoff * (1 << min(attempt, 20)), Self.maximumBackoff)
            schedule(room, after: backoff)
        }
    }
}
