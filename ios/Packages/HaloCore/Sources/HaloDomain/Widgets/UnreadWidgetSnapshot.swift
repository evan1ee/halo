import Foundation

/// What the home-screen and lock-screen widget shows (M16, D89): the app's last evaluated unread counts, not a new
/// evaluation. `counts` is the `AttentionCache` the app writes after `ReadStatePolicy` / `BadgeCalculator`; the widget
/// only adds them up the way the app icon badge does (D82) and never reads room names or messages.
public struct UnreadWidgetSnapshot: Sendable, Equatable {
    public let totalUnread: Int
    public let chatCount: Int
    /// When the app last wrote the counts; `nil` if it never did (not signed in, or never opened).
    public let updatedAt: Date?

    public init(counts: [String: Int], updatedAt: Date?) {
        let positive = counts.values.filter { $0 > 0 }
        totalUnread = positive.reduce(0, +)
        chatCount = positive.count
        self.updatedAt = updatedAt
    }

    /// The badge-style number: capped so it fits a small widget.
    public var countText: String { totalUnread > 99 ? "99+" : "\(totalUnread)" }

    /// One sentence for VoiceOver and the large widget.
    public var summary: String {
        guard updatedAt != nil else { return "Open Halo to see your unread messages." }
        switch (totalUnread, chatCount) {
        case (0, _): return "No unread messages."
        case (1, _): return "1 unread message."
        case (_, 1): return "\(totalUnread) unread messages in 1 chat."
        default: return "\(totalUnread) unread messages in \(chatCount) chats."
        }
    }

    /// Counts older than this are shown as possibly out of date: the app only refreshes them while it runs or a push arrives.
    public static let staleAfter: TimeInterval = 6 * 60 * 60

    public func isStale(at now: Date) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > Self.staleAfter
    }
}
