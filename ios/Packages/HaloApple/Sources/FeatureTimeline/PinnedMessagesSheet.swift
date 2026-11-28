#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// Bottom sheet listing all pinned messages in the room with tap-to-jump and swipe-to-unpin.
struct PinnedMessagesSheet: View {
    let model: TimelineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pins = model.pinnedMessages
        VStack(spacing: 0) {
            HStack {
                Label(
                    pins.count == 1 ? "1 Pinned Message" : "\(pins.count) Pinned Messages",
                    systemImage: "pin.fill"
                )
                .font(HaloTypography.headline)
                .foregroundStyle(HaloColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, HaloSpacing.l)
            .padding(.top, HaloSpacing.l)
            .padding(.bottom, HaloSpacing.m)

            Divider()

            if pins.isEmpty {
                EmptyState(
                    icon: "pin.slash",
                    title: "No pinned messages",
                    message: "Long-press any message to pin it here."
                )
            } else {
                List {
                    ForEach(pins) { pin in
                        Button {
                            dismiss()
                            Task { await model.jump(toEvent: pin.eventID) }
                        } label: {
                            HStack(alignment: .top, spacing: HaloSpacing.s) {
                                SenderAvatar(name: pin.sender, ref: pin.avatar, model: model, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(pin.sender)
                                            .font(HaloTypography.headline)
                                            .foregroundStyle(HaloColor.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: HaloSpacing.s)
                                        if let time = pin.time {
                                            Text(time)
                                                .font(HaloTypography.caption)
                                                .foregroundStyle(HaloColor.textSecondary)
                                        }
                                    }
                                    Text(pin.preview)
                                        .font(HaloTypography.body)
                                        .foregroundStyle(HaloColor.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, HaloSpacing.xxs)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await model.unpin(eventID: pin.eventID) }
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .presentationBackground(HaloColor.bgPrimary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
