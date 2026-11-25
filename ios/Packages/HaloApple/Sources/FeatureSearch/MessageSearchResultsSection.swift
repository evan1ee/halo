#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// The "Messages" part of the chat list's search: filters, coverage, results (MESSAGE_SEARCH §5, FR-13).
public struct MessageSearchResultsSection: View {
    private let model: MessageSearchViewModel
    private let onVerify: (() -> Void)?
    private let onSelect: (MessageSearchViewModel.ResultRow) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    Text(error).foregroundStyle(HaloColor.danger).font(HaloTypography.meta)
                }
                if model.isLoading && model.rows.isEmpty {
                    HStack(spacing: HaloSpacing.s) {
                        ProgressView()
                        Text("Searching messages…").font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                    }
                } else if model.rows.isEmpty && model.searchedQuery == trimmed && model.errorMessage == nil {
                    Text(model.coverage == nil ? "No matching messages" : "No matching messages so far")
                        .font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                        .accessibilityIdentifier("search-no-messages")
                } else {
                    ForEach(model.rows) { row in
                        Button { onSelect(row) } label: { label(row) }
                            .foregroundStyle(HaloColor.textPrimary)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("search-hit-\(row.id)")
                    }
                    if model.hasMore {
                        Button(model.isLoading ? "Loading…" : "Load more messages") { Task { await model.loadMore() } }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .disabled(model.isLoading)
                    }
                }
            } header: {
                Text("Messages")
            }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: HaloSpacing.s) {
                ForEach(SearchFilter.allCases, id: \.self) { filter in
                    let isOn = model.filter == filter
                    Button { model.filter = filter } label: {
                        Text(Self.title(filter))
                            .font(HaloTypography.meta)
                            .padding(.horizontal, HaloSpacing.m)
                            .padding(.vertical, HaloSpacing.xs)
                            .background(isOn ? AnyShapeStyle(HaloColor.accent.opacity(0.18)) : AnyShapeStyle(.quaternary), in: .capsule)
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
        .listRowSeparator(.hidden)
    }

    private func notice(_ coverage: MessageSearchViewModel.Coverage) -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text(coverage.text).accessibilityIdentifier("search-coverage")
            }
            .font(.caption)
            .foregroundStyle(HaloColor.textSecondary)
            if coverage.canVerify, let onVerify {
                Button("Verify this device to read them", action: onVerify)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("search-verify")
            }
        }
        .listRowSeparator(.hidden)
    }

    private func label(_ row: MessageSearchViewModel.ResultRow) -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            HStack {
                Text(row.roomName).font(HaloTypography.captionEmphasis).foregroundStyle(HaloColor.textSecondary).lineLimit(1)
                Spacer()
                Text(Self.formatTime(row.timestamp)).font(.caption2).foregroundStyle(HaloColor.textSecondary)
            }
            Text(row.sender).font(HaloTypography.meta.weight(.medium)).foregroundStyle(HaloColor.textPrimary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                if let symbol = Self.symbol(row.kind) { Image(systemName: symbol).font(.caption).foregroundStyle(HaloColor.textSecondary).accessibilityHidden(true) }
                Text(Self.marked(row)).font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 6 : 2)  // the match must stay visible
            }
            if row.threadRoot != nil {
                Label("In a thread", systemImage: "bubble.left.and.text.bubble.right").font(.caption2).foregroundStyle(HaloColor.textSecondary)
            }
        }
        .padding(.vertical, HaloSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// The snippet with the matching parts in bold.
    static func marked(_ row: MessageSearchViewModel.ResultRow) -> AttributedString {
        var text = AttributedString(row.snippet)
        for range in row.highlights {
            let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let end = text.index(text.startIndex, offsetByCharacters: range.upperBound)
            text[start..<end].font = HaloTypography.meta.weight(.bold)
            text[start..<end].foregroundColor = HaloColor.textPrimary
        }
        return text
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
        calendar.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
