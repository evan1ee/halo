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
        do { return MatrixTimelineSession(timeline: try await room.timeline()) } catch { throw ErrorMapper.map(error) }
    }
}

final class MatrixTimelineSession: TimelineSession {
    private let timeline: Timeline

    init(timeline: Timeline) { self.timeline = timeline }

    func items() -> AsyncStream<HaloDomain.TimelineDiff> {
        let (output, continuation) = AsyncStream<HaloDomain.TimelineDiff>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [timeline] in
            let (raw, rawContinuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: Listener(rawContinuation))
            defer { handle.cancel() }
            for await batch in raw {
                for update in batch { continuation.yield(TimelineMapper.map(update)) }
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

    func close() async {}
}

private final class Listener: TimelineListener {
    private let continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation
    init(_ continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation) { self.continuation = continuation }
    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) { continuation.yield(diff) }
}
