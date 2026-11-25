import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPlatform
import UserNotifications

/// Push gateway configuration and iOS notification permission status (ADR-0022 step 2).
extension AppRoot {
    static func pushConfiguration() -> (appID: String, gateway: URL)? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "HaloPushAppID") as? String, !appID.isEmpty,
              let raw = Bundle.main.object(forInfoDictionaryKey: "HaloPushGatewayURL") as? String, !raw.isEmpty,
              let gateway = URL(string: raw) else { return nil }
        return (appID, gateway)
    }

    nonisolated func notificationStatus() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off in iOS Settings"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}

/// Reply or Mark as read tapped on a notification (M18-7, NOTIFICATIONS FR-10).
struct NotificationAction: Sendable {
    enum Kind: Sendable { case reply, markRead }
    let kind: Kind
    let room: RoomID
    let text: String?
    /// The notification's request identifier: an action runs once per notification.
    let notification: String
    let date: Date
}

extension AppRoot {
    /// Does what the notification action asks, with Halo possibly started in the background for it, and says when it didn't work.
    func perform(_ action: NotificationAction) async {
        await begin()
        let outcome: NotificationActionOutcome
        switch action.kind {
        case .reply:
            outcome = await notificationActions.reply(text: action.text ?? "", to: action.room, notification: action.notification)
        case .markRead:
            outcome = await notificationActions.markRead(room: action.room, at: action.date, notification: action.notification)
        }
        switch (action.kind, outcome) {
        case (.reply, .failed):
            await tell("Your reply wasn't sent", body: "Couldn't reach Halo's server. Your message is saved as a draft in the chat: \(action.text ?? "")", room: action.room)
        case (.markRead, .failed):
            await tell("Couldn't mark as read", body: "Open Halo to read the chat.", room: action.room)
        case (.markRead, .done):
            await clearDelivered(for: action.room)
            _ = await refreshInBackground()  // the badge and the widgets follow the read
        default:
            break
        }
        if outcome == .done || outcome == .queued { await receipts.flush() }
    }

    private func tell(_ title: String, body: String, room: RoomID) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = room.rawValue
        content.userInfo = ["room_id": room.rawValue]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func clearDelivered(for room: RoomID) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { $0.request.content.threadIdentifier == room.rawValue }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
