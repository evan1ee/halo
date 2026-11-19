import UserNotifications

/// Composition root of the notification service extension. The fetch-through-SDK pipeline is M1
/// (gate G-NSE, ADR-0016); until then the notification is delivered unchanged. It never sets
/// `aps.badge` and never creates attention from a payload (AGENTS.md §17).
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        contentHandler(request.content)
    }
}
