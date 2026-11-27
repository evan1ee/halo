#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// The "Messages" part of the chat list's search: filters, coverage, and conversation-style message hits with room avatars and attachment cards (MESSAGE_SEARCH §5, FR-13).
public struct MessageSearchResultsSection: View {
    private let model: MessageSearchViewModel
    private let onVerify: (() -> Void)?
    private let onSelect: (MessageSearchViewModel.ResultRow) -> Void

    public init(model: MessageSearchViewModel, onVerify: (() -> Void)? = nil, onSelect: @escaping (MessageSearchViewModel.ResultRow) -> Void) {
        self.model = model
        self.onVerify = onVerify
        self.onSelect = onSelect
    }

    public var body: some View {
        let trimmed = model.trimmedQuery
        if !trimmed.isEmpty {
            Section {
                filters
                if let coverage = model.coverage { notice(coverage) }
                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(HaloColor.danger)
                        .font(HaloTypography.meta)
                        .listRowSeparator(.hidden)
                }
                if model.isLoading && model.rows.isEmpty {
                    HStack(spacing: HaloSpacing.s) {
                        ProgressView()
                        Text("Searching messages…").font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                    }
                    .padding(.vertical, HaloSpacing.s)
                    .listRowSeparator(.hidden)
                } else if model.rows.isEmpty && model.searchedQuery == trimmed && model.errorMessage == nil {
                    VStack(spacing: HaloSpacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(HaloColor.textSecondary.opacity(0.6))
                            .accessibilityHidden(true)
                        Text(model.coverage == nil ? "No matching messages" : "No matching messages so far")
                            .font(.subheadline)
                            .foregroundStyle(HaloColor.textSecondary)
                            .accessibilityIdentifier("search-no-messages")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HaloSpacing.xl)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(model.rows) { row in
                        Button { onSelect(row) } label: {
                            MessageSearchHitRow(row: row, model: model)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("search-hit-\(row.id)")
                    }
                    if model.hasMore {
                        Button(model.isLoading ? "Loading…" : "Load more messages") { Task { await model.loadMore() } }
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, HaloSpacing.xs)
                            .disabled(model.isLoading)
                            .listRowSeparator(.hidden)
                            .onAppear { Task { await model.loadMore() } }
                    }
                }
            }
            .listSectionSeparator(.hidden, edges: .top)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: HaloSpacing.s) {
                ForEach(SearchFilter.allCases, id: \.self) { filter in
                    let isOn = model.filter == filter
                    Button { model.filter = filter } label: {
                        Text(Self.title(filter))
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? HaloColor.accent : HaloColor.textSecondary)
                            .padding(.horizontal, HaloSpacing.m)
                            .padding(.vertical, 6)
                            .background(
                                isOn ? HaloColor.accent.opacity(0.16) : HaloColor.bgSecondary,
                                in: .capsule
                            )
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("search-filter-\(filter.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: HaloSpacing.l, bottom: 2, trailing: HaloSpacing.l))
        .listRowSeparator(.hidden)
    }

    private func notice(_ coverage: MessageSearchViewModel.Coverage) -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text(coverage.text).accessibilityIdentifier("search-coverage")
            }
            .font(.caption)
            .foregroundStyle(HaloColor.textSecondary)
            if coverage.canVerify, let onVerify {
                Button("Verify this device to read them", action: onVerify)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("search-verify")
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: HaloSpacing.l, bottom: 4, trailing: HaloSpacing.l))
        .listRowSeparator(.hidden)
    }

    /// Combined `<sender>: <snippet>` preview with matched query ranges bolded in primary colour.
    static func marked(_ row: MessageSearchViewModel.ResultRow) -> AttributedString {
        var result = AttributedString()
        if !row.sender.isEmpty {
            var senderPart = highlighted(
                row.sender,
                ranges: row.senderHighlights,
                matchFont: .subheadline.weight(.semibold),
                matchColor: HaloColor.textPrimary
            )
            senderPart.append(AttributedString(": "))
            result.append(senderPart)
        }
        let bodyPart = highlighted(
            row.snippet,
            ranges: row.highlights,
            matchFont: .subheadline.weight(.semibold),
            matchColor: HaloColor.textPrimary
        )
        result.append(bodyPart)
        return result
    }

    /// Attachment title with matched query ranges bolded.
    static func markedAttachmentTitle(_ row: MessageSearchViewModel.ResultRow) -> AttributedString {
        highlighted(
            row.snippet,
            ranges: row.highlights,
            matchFont: .subheadline.weight(.semibold),
            matchColor: HaloColor.textPrimary
        )
    }

    private static func highlighted(
        _ text: String,
        ranges: [Range<Int>],
        matchFont: Font,
        matchColor: Color
    ) -> AttributedString {
        guard !ranges.isEmpty else { return AttributedString(text) }
        var attributed = AttributedString(text)
        let charCount = text.count
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= charCount && range.lowerBound < range.upperBound {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: range.upperBound)
            attributed[start..<end].font = matchFont
            attributed[start..<end].foregroundColor = matchColor
        }
        return attributed
    }

    static func title(_ filter: SearchFilter) -> String {
        switch filter {
        case .all: "All"
        case .messages: "Messages"
        case .media: "Media"
        case .files: "Files"
        case .links: "Links"
        }
    }

    static func symbol(_ kind: SearchKind) -> String? {
        switch kind {
        case .message: nil
        case .media: "photo"
        case .file: "doc"
        case .link: "link"
        }
    }

    static func formatTime(_ date: Date, calendar: Calendar = .current) -> String {
        MessageSearchViewModel.ResultRow.formatTime(date, calendar: calendar)
    }
}

/// Conversation-style search hit row matching the room-list layout: 52 pt leading room avatar, bold room title + relative timestamp,
/// and either an inline `<sender>: <highlighted snippet>` preview or a rounded attachment card (`PNG (1.4 MB)`).
private struct MessageSearchHitRow: View {
    let row: MessageSearchViewModel.ResultRow
    let model: MessageSearchViewModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: HaloSpacing.m) {
            SearchRoomAvatarView(name: row.roomName, ref: row.roomAvatar, model: model)
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                if typeSize.isAccessibilitySize {
                    Text(row.roomName)
                        .font(HaloTypography.bodyEmphasis)
                        .foregroundStyle(HaloColor.textPrimary)
                        .lineLimit(2)
                    Text(row.formattedTime)
                        .font(HaloTypography.caption)
                        .foregroundStyle(HaloColor.textSecondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                        Text(row.roomName)
                            .font(HaloTypography.bodyEmphasis)
                            .foregroundStyle(HaloColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: HaloSpacing.xs)
                        Text(row.formattedTime)
                            .font(HaloTypography.caption)
                            .foregroundStyle(HaloColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let attachment = row.attachment {
                    SearchAttachmentCardView(row: row, attachment: attachment, model: model)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                        if row.kind == .link {
                            Image(systemName: "link")
                                .font(.caption)
                                .foregroundStyle(HaloColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                        Text(MessageSearchResultsSection.marked(row))
                            .font(.subheadline)
                            .foregroundStyle(HaloColor.textSecondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 6 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                if row.threadRoot != nil {
                    Label("In a thread", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption2)
                        .foregroundStyle(HaloColor.textSecondary)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading]
            }
        }
        .padding(.vertical, HaloSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .top)
        .contentShape(.rect)
    }
}

private struct SearchRoomAvatarView: View {
    let name: String
    let ref: MediaRef?
    let model: MessageSearchViewModel
    @State private var data: Data?

    init(name: String, ref: MediaRef?, model: MessageSearchViewModel) {
        self.name = name
        self.ref = ref
        self.model = model
        _data = State(initialValue: model.cachedThumbnail(for: ref))
    }

    var body: some View {
        AvatarCircle(name: name, imageData: data, size: 52, showsOuterFrame: false)
            .task(id: ref) {
                guard let ref else { data = nil; return }
                if let cached = model.cachedThumbnail(for: ref) {
                    data = cached
                    return
                }
                data = await model.loadThumbnail(ref, pixelSize: 96)
            }
    }
}

/// Rounded inline attachment card (`The only way` / `PNG (1.4 MB)`) with decrypted thumbnail or crisp format tile.
private struct SearchAttachmentCardView: View {
    let row: MessageSearchViewModel.ResultRow
    let attachment: SearchAttachment
    let model: MessageSearchViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var data: Data?

    init(row: MessageSearchViewModel.ResultRow, attachment: SearchAttachment, model: MessageSearchViewModel) {
        self.row = row
        self.attachment = attachment
        self.model = model
        _data = State(initialValue: model.cachedThumbnail(for: attachment.thumbnail))
    }

    private var fallbackSymbol: String {
        switch attachment.mediaKind {
        case .image: "photo.fill"
        case .video: "video.fill"
        case .audio: "waveform"
        case .file: "doc.text.fill"
        }
    }

    var body: some View {
        HStack(spacing: HaloSpacing.s) {
            ZStack {
                if let data {
                    DecodedImage(data, maxPixel: ImagePipeline.Size.listRow) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        fallbackTile
                    }
                    if attachment.mediaKind == .video {
                        Circle()
                            .fill(HaloColor.mediaOverlayBackground)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                            }
                    }
                } else {
                    fallbackTile
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: HaloRadius.small, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(MessageSearchResultsSection.markedAttachmentTitle(row))
                    .font(.subheadline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(attachment.subtitle)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, HaloSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HaloColor.bgSecondary, in: .rect(cornerRadius: HaloRadius.medium, style: .continuous))
        .task(id: attachment.thumbnail) {
            guard let ref = attachment.thumbnail else { data = nil; return }
            if let cached = model.cachedThumbnail(for: ref) {
                data = cached
                return
            }
            data = await model.loadThumbnail(ref, pixelSize: 120)
        }
    }

    private var fallbackTile: some View {
        ZStack {
            HaloColor.accent.opacity(0.14)
            Image(systemName: fallbackSymbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HaloColor.accent)
        }
    }
}
#endif
