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

    /// Sends every item of `payload` to `room`, then discards it.
    public func deliver(_ payload: SharePayload, to room: RoomID) async throws(HaloError) {
        let session = try await timelines.open(room: room)
        do throws(HaloError) {
            for item in payload.items where !sent.contains(item.id) {
                try await send(item, of: payload, via: session)
                sent.insert(item.id)
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        inbox.discard(payload)
        for item in payload.items { sent.remove(item.id) }
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
                data: data, filename: item.filename ?? "image", mimeType: item.mimeType ?? "image/jpeg", width: nil, height: nil
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
