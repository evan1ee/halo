import Foundation
import UserNotifications

/// The actions on a message notification (NOTIFICATIONS FR-10, M18-7): the identifiers the notification extension and the app
/// agree on, and the category the app registers.
public enum NotificationActions {
    public static let messageCategory = "one.mbm.halo.message"
    public static let reply = "one.mbm.halo.reply"
    public static let markRead = "one.mbm.halo.mark-read"

    /// Reply (typed in the notification) and Mark as read. Neither opens the app: iOS runs Halo in the background for them.
    public static func categories() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: reply, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: markRead, title: "Mark as read", options: [])
        return [UNNotificationCategory(identifier: messageCategory, actions: [reply, read], intentIdentifiers: [], options: [])]
    }

    public static func register(_ center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(categories())
    }
}
