import SwiftUI

/// Empty state wrapping SwiftUI's `ContentUnavailableView` (`docs/design/DESIGN_SYSTEM.md` §7–8).
public struct EmptyState: View {
    private let icon: String
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let onAction: (() -> Void)?

    public init(
        icon: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview("EmptyState — Light") {
    EmptyState(
        icon: "bubble.left.and.bubble.right",
        title: "No conversations yet",
        message: "Start a new chat to message someone on Matrix.",
        actionTitle: "New chat",
        onAction: {}
    )
}

#Preview("EmptyState — Dark") {
    EmptyState(icon: "checkmark.circle", title: "All caught up", message: "No unread messages.")
        .preferredColorScheme(.dark)
}

#Preview("EmptyState — AX5") {
    EmptyState(icon: "bubble.left.and.bubble.right", title: "No conversations yet", message: "Start a new chat.")
        .environment(\.dynamicTypeSize, .accessibility5)
}
