#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full "Message info" sheet showing who sent the message, when it arrived, delivery/encryption/edit status,
/// everyone who has read up to it (with timestamps when available), and event metadata (TIMELINE FR-6, M20-9).
struct MessageInfoView: View {
    let row: TimelineRow
    let model: TimelineViewModel
    let isPinned: Bool
    let isRoomEncrypted: Bool?
    let onViewEditHistory: (() -> Void)?
    let onViewSource: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MessageInfoContent(
                    row: row,
                    model: model,
                    isPinned: isPinned,
                    isRoomEncrypted: isRoomEncrypted,
                    onViewEditHistory: onViewEditHistory.map { action in { dismiss(); action() } },
                    onViewSource: onViewSource.map { action in { dismiss(); action() } }
                )
                .padding(HaloSpacing.m)
            }
            .background(HaloColor.bgPrimary)
            .navigationTitle("Message info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("message-info-sheet")
    }
}

/// Pure SwiftUI content of `MessageInfoView`, reusable inside both the sheet and visual layout tests.
struct MessageInfoContent: View {
    let row: TimelineRow
    let model: TimelineViewModel
    let isPinned: Bool
    let isRoomEncrypted: Bool?
    let onViewEditHistory: (() -> Void)?
    let onViewSource: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copiedEventID = false

    private var summaryText: String {
        if row.isSticker { return row.text.isEmpty ? "Sticker" : "Sticker: \(row.text)" }
        if let poll = row.poll { return "Poll: \(poll.question)" }
        if let video = row.video { return video.caption ?? video.filename }
        if let audio = row.audio { return audio.isVoice ? "Voice message" : audio.name }
        if let file = row.file { return file.name }
        if let location = row.location { return location.title }
        if row.image != nil, !row.showsText { return "Photo" }
        return row.text
    }

    private var deliverySummary: String {
        if let delivery = row.delivery {
            switch delivery {
            case .sending: return "Sending…"
            case .failed: return row.status ?? "Not sent"
            case .sent: return "Sent"
            case .read: return row.seenBy == 1 ? "Read by 1 person" : "Read by \(row.seenBy) people"
            }
        }
        return "Received"
    }

    private var deliveryColor: Color {
        if case .failed = row.delivery { return HaloColor.danger }
        if case .read = row.delivery { return HaloColor.accent }
        return HaloColor.textSecondary
    }

    private func formatTimestamp(_ date: Date) -> String {
        model.formatInfoTimestamp(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.m) {
            card {
                VStack(alignment: .leading, spacing: HaloSpacing.s) {
                    HStack(alignment: .center, spacing: HaloSpacing.s) {
                        SenderAvatar(name: row.sender ?? (row.isOwn ? "You" : "?"), ref: row.avatar, model: model, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.sender ?? (row.isOwn ? "You" : "Unknown"))
                                .font(HaloTypography.headline)
                                .foregroundStyle(HaloColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let senderID = row.senderID {
                                Text(senderID)
                                    .font(HaloTypography.meta)
                                    .foregroundStyle(HaloColor.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !summaryText.isEmpty {
                        Text(summaryText)
                            .font(HaloTypography.body)
                            .foregroundStyle(HaloColor.textPrimary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(HaloSpacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(HaloColor.bgPrimary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
                    }
                }
            }

            sectionHeader("Details")
            card {
                VStack(alignment: .leading, spacing: HaloSpacing.s) {
                    if let timestamp = row.timestamp {
                        infoRow(title: "Sent", value: formatTimestamp(timestamp))
                    } else if let time = row.time {
                        infoRow(title: "Sent", value: time)
                    }
                    Divider()
                    infoRow(title: "Status", value: deliverySummary, valueColor: deliveryColor)
                    if let isRoomEncrypted {
                        Divider()
                        infoRow(
                            title: "Encryption",
                            value: isRoomEncrypted ? "End-to-end encrypted" : "Not encrypted",
                            valueColor: isRoomEncrypted ? HaloColor.textPrimary : HaloColor.warning
                        )
                    }
                    if row.isEdited {
                        Divider()
                        if let onViewEditHistory {
                            Button(action: onViewEditHistory) {
                                infoRow(title: "Edited", value: "View edit history", valueColor: HaloColor.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("message-info-edit-history")
                        } else {
                            infoRow(title: "Edited", value: "Yes")
                        }
                    }
                    if isPinned {
                        Divider()
                        infoRow(title: "Pinned", value: "Pinned in room")
                    }
                    if let eventType = row.eventType {
                        Divider()
                        infoRow(title: "Type", value: eventType, monospaced: true)
                    }
                    if let eventID = row.eventID?.rawValue {
                        Divider()
                        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                            Text("Event ID")
                                .font(HaloTypography.meta)
                                .foregroundStyle(HaloColor.textSecondary)
                            Text(eventID)
                                .font(.footnote.monospaced())
                                .foregroundStyle(HaloColor.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            #if canImport(UIKit)
                            Button {
                                UIPasteboard.general.string = eventID
                                copiedEventID = true
                            } label: {
                                Label(copiedEventID ? "Copied" : "Copy event ID", systemImage: copiedEventID ? "checkmark" : "doc.on.doc")
                                    .font(HaloTypography.meta)
                                    .foregroundStyle(HaloColor.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("message-info-copy-event-id")
                            #endif
                        }
                    }
                }
            }

            sectionHeader(row.allReaders.isEmpty ? "Read by" : "Read by (\(row.allReaders.count))")
            card {
                if row.allReaders.isEmpty {
                    Text("No read receipts yet")
                        .font(HaloTypography.body)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("message-info-no-readers")
                } else {
                    VStack(alignment: .leading, spacing: HaloSpacing.s) {
                        ForEach(Array(row.allReaders.enumerated()), id: \.element.id) { index, reader in
                            if index > 0 { Divider() }
                            MessageInfoReaderRow(
                                reader: reader,
                                model: model,
                                formattedReadAt: reader.readAt.map(formatTimestamp)
                            )
                        }
                    }
                }
            }

            if !row.reactions.isEmpty {
                sectionHeader("Reactions")
                card {
                    ReactionFlowLayout(alignment: .leading, spacing: HaloSpacing.xs) {
                        ForEach(row.reactions) { chip in
                            Text("\(chip.key) \(chip.count)")
                                .font(HaloTypography.meta)
                                .padding(.horizontal, HaloSpacing.s)
                                .padding(.vertical, HaloSpacing.xxs)
                                .background(
                                    chip.reactedByMe ? HaloColor.accent.opacity(0.2) : HaloColor.bgPrimary,
                                    in: Capsule()
                                )
                        }
                    }
                }
            }

            if row.source != nil, let onViewSource {
                card {
                    Button(action: onViewSource) {
                        HStack(spacing: HaloSpacing.s) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(HaloColor.accent)
                            Text("View source")
                                .font(HaloTypography.body)
                                .foregroundStyle(HaloColor.accent)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("message-info-view-source")
                }
            }
        }
        .task(id: copiedEventID) {
            guard copiedEventID else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedEventID = false
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(HaloTypography.captionEmphasis)
            .foregroundStyle(HaloColor.textSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, HaloSpacing.xs)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HaloSpacing.m)
            .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
    }

    @ViewBuilder
    private func infoRow(title: LocalizedStringKey, value: String, valueColor: Color = HaloColor.textSecondary, monospaced: Bool = false) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(monospaced ? .footnote.monospaced() : HaloTypography.body)
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.s) {
                Text(title)
                    .foregroundStyle(HaloColor.textPrimary)
                Spacer(minLength: HaloSpacing.s)
                Text(value)
                    .font(monospaced ? .footnote.monospaced() : HaloTypography.body)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// One reader entry inside `MessageInfoView` and `ReadersView` (avatar, display name, Matrix ID, optional read timestamp).
struct MessageInfoReaderRow: View {
    let reader: TimelineRow.Reader
    let model: TimelineViewModel
    let formattedReadAt: String?

    var body: some View {
        HStack(alignment: .center, spacing: HaloSpacing.s) {
            SenderAvatar(name: reader.name, ref: reader.avatar, model: model, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(reader.name)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if reader.id != reader.name {
                    Text(reader.id)
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let formattedReadAt {
                    Text("Read \(formattedReadAt)")
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, HaloSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader-row-\(reader.id)")
    }
}
#endif
