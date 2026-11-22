import Foundation
import HaloDomain
import HaloFoundation

/// Sends what the share extension staged into a room the person picks (M16). Items go out one at a time through the
/// timeline's normal send path, so they look unconfirmed until the server accepts them (AGENTS §4.4). A payload is
/// discarded only once every item is sent; after a failure the items already sent are skipped on retry.
public actor ShareCoordinator {
    private let inbox: any ShareInboxPort
    private let timelines: any TimelinePort
    private var sent: Set<String> = []

    public init(inbox: any ShareInboxPort, timelines: any TimelinePort) {
        self.inbox = inbox
        self.timelines = timelines
    }

    /// The staged payloads waiting for a chat.
    public func pending() -> [SharePayload] { (try? inbox.pending()) ?? [] }

    /// Removes a payload without sending it.
    public func dismiss(_ payload: SharePayload) {
        inbox.discard(payload)
    }

    /// How a delivery ended.
    public enum Delivery: Sendable, Equatable {
        /// Every item is on the server (only known when `confirmingFor` was given).
        case confirmed
        /// Handed to the send queue; the server hasn't confirmed yet (no confirmation asked for, or it took too long). The queue
        /// is in the shared store, so Halo finishes the send when it next runs.
        case queued
    }

    /// Sends every item of `payload` to `room`, then discards it. With `confirmingFor`, waits up to that long for the server to
    /// accept the messages (the share extension, which must not close earlier); a failed echo throws.
    @discardableResult
    public func deliver(_ payload: SharePayload, to room: RoomID, confirmingFor timeout: Duration? = nil) async throws(HaloError) -> Delivery {
        let session = try await timelines.open(room: room)
        let remaining = payload.items.filter { !sent.contains($0.id) }
        let expected = remaining.filter { item in
            switch item.kind {
            case .text, .url: item.text?.isEmpty == false
            case .image, .file: true
            }
        }.count
        // Subscribe before sending, so the first diff is the baseline and every echo of ours comes after it.
        var watcher: Task<SendConfirmation.State, Never>?
        if let limit = timeout {
            let stream = session.items()
            watcher = Task { await Self.watch(stream, expected: expected, limit: limit) }
        }
        var result = Delivery.queued
        do throws(HaloError) {
            for item in remaining {
                try await send(item, of: payload, via: session)
                sent.insert(item.id)
            }
            if let watcher, await watcher.value == .failed { throw HaloError.network(retryable: true) }
            if let watcher, await watcher.value == .confirmed { result = .confirmed }
        } catch {
            watcher?.cancel()
            await session.close()
            throw error
        }
        await session.close()
        inbox.discard(payload)
        for item in payload.items { sent.remove(item.id) }
        return result
    }

    /// Reads the timeline until `expected` messages are confirmed, one fails, or `limit` passes.
    private static func watch(_ stream: AsyncStream<TimelineDiff>, expected: Int, limit: Duration) async -> SendConfirmation.State {
        guard expected > 0 else { return .confirmed }
        return await withTaskGroup(of: SendConfirmation.State.self) { group in
            group.addTask {
                var tracker = SendConfirmation(expected: expected)
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

    private func send(_ item: SharedItem, of payload: SharePayload, via session: any TimelineSession) async throws(HaloError) {
        switch item.kind {
        case .text, .url:
            guard let text = item.text, !text.isEmpty else { return }
            try await session.send(text: text)
        case .image:
            let data = try inbox.data(of: item, in: payload)
            guard data.count <= OutgoingImage.maximumBytes else { throw .invalidInput("SHARE_TOO_LARGE") }
            try await session.sendImage(OutgoingImage(
                data: data, filename: item.filename ?? "image", mimeType: item.mimeType ?? "image/jpeg", width: item.width, height: item.height
            ))
        case .file:
            let data = try inbox.data(of: item, in: payload)
            guard data.count <= OutgoingFile.maximumBytes else { throw .invalidInput("SHARE_TOO_LARGE") }
            try await session.sendFile(OutgoingFile(
                data: data, filename: item.filename ?? "file", mimeType: item.mimeType ?? "application/octet-stream"
            ))
        }
    }
}
