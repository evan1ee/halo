#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// Lifecycle banner shown in place of the composer when the open room is upgraded, left, banned, or pending knock (M20-8, GA-23).
struct RoomLifecycleBanner: View {
    let state: RoomBannerState
    let isWorking: Bool
    let errorMessage: String?
    let onOpenSuccessor: (RoomID) -> Void
    let onLeaveAndForget: () -> Void
    let onForget: () -> Void
    let onCancelKnock: () -> Void

    private var icon: String {
        switch state {
        case .upgraded: "arrow.up.circle.fill"
        case .left: "rectangle.portrait.and.arrow.right"
        case .banned: "hand.raised.fill"
        case .knocked: "door.left.hand.closed"
        }
    }

    private var title: String {
        switch state {
        case .upgraded: "This room has been upgraded"
        case .left: "You left this room"
        case .banned: "You were banned from this room"
        case .knocked: "Join request sent"
        }
    }

    private var detail: String {
        switch state {
        case .upgraded(let successor):
            successor.reason ?? "New messages now go to the replacement room."
        case .left:
            "You can't send new messages here. Forget this room to remove it."
        case .banned:
            "You can't rejoin or send messages here. Forget this room to remove it."
        case .knocked:
            "Waiting for a room administrator to accept your request."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.s) {
            HStack(alignment: .top, spacing: HaloSpacing.s) {
                Image(systemName: icon)
                    .font(HaloTypography.bodyEmphasis)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(isDestructiveState ? HaloColor.danger : HaloColor.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HaloTypography.headline)
                        .foregroundStyle(HaloColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("room-lifecycle-error")
            }

            actionsRow
        }
        .padding(HaloSpacing.m)
        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
        .padding(.horizontal, HaloSpacing.m)
        .padding(.vertical, HaloSpacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-lifecycle-banner")
    }

    private var isDestructiveState: Bool {
        if case .banned = state { return true }
        return false
    }

    @ViewBuilder
    private var actionsRow: some View {
        if isWorking {
            HStack(spacing: HaloSpacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Updating…")
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
            }
            .frame(minHeight: 36)
        } else {
            switch state {
            case .upgraded(let successor):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HaloSpacing.s) {
                        openNewRoomButton(successor.roomID)
                        leaveOldRoomButton
                    }
                    VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                        openNewRoomButton(successor.roomID)
                        leaveOldRoomButton
                    }
                }
            case .left, .banned:
                Button(role: .destructive) {
                    onForget()
                } label: {
                    Text("Forget room")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("lifecycle-forget-room")
            case .knocked:
                Button(role: .destructive) {
                    onCancelKnock()
                } label: {
                    Text("Cancel request")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lifecycle-cancel-knock")
            }
        }
    }

    private func openNewRoomButton(_ successorID: RoomID) -> some View {
        Button {
            onOpenSuccessor(successorID)
        } label: {
            Text("Go to new room")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("lifecycle-open-successor")
    }

    private var leaveOldRoomButton: some View {
        Button(role: .destructive) {
            onLeaveAndForget()
        } label: {
            Text("Leave old room")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("lifecycle-leave-old-room")
    }
}
#endif
