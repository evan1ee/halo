import Testing
import UserNotifications
@testable import HaloPlatform

@Suite("NotificationActions")
struct NotificationActionsTests {
    @Test("message notifications offer Reply (typed in place) and Mark as read, and neither opens the app (M18-7)")
    func category() throws {
        let categories = NotificationActions.categories()
        let category = try #require(categories.first { $0.identifier == NotificationActions.messageCategory })
        #expect(categories.count == 1)
        #expect(category.actions.map(\.identifier) == [NotificationActions.reply, NotificationActions.markRead])
        #expect(category.actions[0] is UNTextInputNotificationAction)
        #expect(category.actions.allSatisfy { !$0.options.contains(.foreground) })
    }
}
