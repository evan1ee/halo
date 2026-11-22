import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// State of the "Send to…" sheet that follows a share from another app (M16). It shows the oldest staged payload; the
/// person picks a chat, or dismisses it. Sending itself is `ShareCoordinator`'s.
@MainActor @Observable
public final class ShareHandoffViewModel {
    public private(set) var current: SharePayload?
    public private(set) var isSending = false
    public private(set) var errorMessage: String?

    private let coordinator: ShareCoordinator
    /// Called with the room after a successful send, so the app can open it.
    public var onSent: @MainActor (RoomID) -> Void

    public init(coordinator: ShareCoordinator, onSent: @escaping @MainActor (RoomID) -> Void = { _ in }) {
        self.coordinator = coordinator
        self.onSent = onSent
    }

    /// Looks for a staged payload; call when the app becomes active. A sheet already open or a send under way is left alone.
    public func refresh() async {
        guard !isSending, current == nil else { return }
        current = await coordinator.pending().first
        errorMessage = nil
    }

    public func send(to room: RoomID) async {
        guard let payload = current, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await coordinator.deliver(payload, to: room)
            current = nil
            onSent(room)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Drops the payload without sending it.
    public func discard() async {
        guard let payload = current, !isSending else { return }
        await coordinator.dismiss(payload)
        current = nil
        errorMessage = nil
    }

    /// The sheet was swiped away: the payload stays staged and is offered again at the next `refresh()`.
    public func sheetClosed() {
        current = nil
        errorMessage = nil
    }

    static func message(for error: HaloError) -> String {
        if error == .invalidInput("SHARE_TOO_LARGE") { return "That file is too large to send." }
        return HaloErrorCopy.message(for: error)
    }
}
