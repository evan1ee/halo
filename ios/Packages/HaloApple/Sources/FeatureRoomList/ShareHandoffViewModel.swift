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

    /// What the last send reached: confirmed by the server, or queued for Halo to finish.
    public private(set) var lastDelivery: ShareCoordinator.Delivery?

    private let coordinator: ShareCoordinator
    /// `nil` in the app (sending is confirmed in the timeline); the share extension waits this long for the server.
    private let confirmingFor: Duration?
    /// Called with the room after a successful send, so the app can open it.
    public var onSent: @MainActor (RoomID) -> Void

    public init(coordinator: ShareCoordinator, confirmingFor: Duration? = nil, onSent: @escaping @MainActor (RoomID) -> Void = { _ in }) {
        self.coordinator = coordinator
        self.confirmingFor = confirmingFor
        self.onSent = onSent
    }

    /// Looks for a staged payload; call when the app becomes active. A sheet already open or a send under way is left alone.
    public func refresh() async {
        guard !isSending, current == nil else { return }
        current = await coordinator.pending().first
        errorMessage = nil
    }

    /// Shows a payload the caller just staged (the share extension), instead of the oldest one in the inbox.
    public func present(_ payload: SharePayload) {
        current = payload
        errorMessage = nil
    }

    public func send(to room: RoomID) async {
        guard let payload = current, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            lastDelivery = try await coordinator.deliver(payload, to: room, confirmingFor: confirmingFor)
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
