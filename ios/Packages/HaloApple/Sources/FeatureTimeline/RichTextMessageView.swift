#if canImport(SwiftUI)
import HaloBotRendering
import HaloDesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a structured Matrix HTML message (`RichTextDocument`: fenced code blocks with copy, tap-to-reveal spoilers,
/// safe bounded tables, nested lists, headings, and blockquotes; TIMELINE FR-13, M20-10).
struct RichTextMessageView: View {
    let document: RichTextDocument
    let isOwn: Bool
    /// Optional initial revealed spoiler indices, used by snapshot tests to render both hidden and revealed states.
    var initiallyRevealedSpoilers: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.s) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { blockIndex, block in
                blockView(block, blockIndex: blockIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("rich-text-message")
    }

    @ViewBuilder
    private func blockView(_ block: RichTextDocument.Block, blockIndex: Int) -> some View {
        switch block {
        case .text(let segments):
            InlineSegmentsView(
                segments: segments,
                idPrefix: "b\(blockIndex)",
                initiallyRevealed: initiallyRevealedSpoilers
            )
        case .heading(let level, let segments):
            InlineSegmentsView(
                segments: segments,
                idPrefix: "h\(blockIndex)",
                initiallyRevealed: initiallyRevealedSpoilers
            )
            .font(level <= 2 ? HaloTypography.headline : HaloTypography.bodyEmphasis)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let segments):
            HStack(alignment: .top, spacing: HaloSpacing.s) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(HaloColor.accent.opacity(0.6))
                    .frame(width: 3)
                InlineSegmentsView(
                    segments: segments,
                    idPrefix: "q\(blockIndex)",
                    initiallyRevealed: initiallyRevealedSpoilers
                )
                .foregroundStyle(HaloColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .list(let items):
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                    HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                        Text(item.marker)
                            .font(HaloTypography.body)
                            .foregroundStyle(HaloColor.textSecondary)
                            .fixedSize()
                        InlineSegmentsView(
                            segments: item.segments,
                            idPrefix: "l\(blockIndex)-\(itemIndex)",
                            initiallyRevealed: initiallyRevealedSpoilers
                        )
                    }
                    .padding(.leading, CGFloat(min(item.depth, 5)) * 14)
                }
            }
        case .table(let table):
            SafeTableView(table: table)
        case .divider:
            Divider()
                .padding(.vertical, HaloSpacing.xxs)
        }
    }
}

/// Renders inline text interleaved with tap-to-reveal spoilers.
private struct InlineSegmentsView: View {
    let segments: [RichTextDocument.InlineSegment]
    let idPrefix: String
    let initiallyRevealed: Set<String>

    var body: some View {
        if segments.count == 1, case .styled(let attr) = segments[0] {
            Text(attr)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    switch segment {
                    case .styled(let attr):
                        let trimmed = Self.trimEdgeWhitespace(attr)
                        if !trimmed.characters.isEmpty {
                            Text(trimmed)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .spoiler(let reason, let content):
                        let key = "\(idPrefix)-\(index)"
                        SpoilerPillView(
                            reason: reason,
                            content: content,
                            initiallyRevealed: initiallyRevealed.contains(key)
                        )
                    }
                }
            }
        }
    }

    private static func trimEdgeWhitespace(_ attr: AttributedString) -> AttributedString {
        var result = attr
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.index(afterCharacter: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
        }
        return result
    }
}

/// Monospaced fenced code block with optional language label and one-tap Copy button (TIMELINE FR-13, M20-10).
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HaloSpacing.s) {
                Text(language?.uppercased() ?? "CODE")
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: HaloSpacing.s)
                #if canImport(UIKit)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    HStack(spacing: HaloSpacing.xxs) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                            .fixedSize()
                    }
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(copied ? HaloColor.success : HaloColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
                .accessibilityIdentifier("code-block-copy")
                #endif
            }
            .padding(.horizontal, HaloSpacing.s)
            .padding(.vertical, HaloSpacing.xs)
            .background(HaloColor.bgSecondary.opacity(0.6))

            Divider()

            let codeText = Text(code)
                .font(.footnote.monospaced())
                .foregroundStyle(HaloColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(HaloSpacing.s)

            ViewThatFits(in: .horizontal) {
                codeText
                ScrollView(.horizontal, showsIndicators: true) {
                    codeText
                }
            }
        }
        .background(HaloColor.bgPrimary.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                .strokeBorder(HaloColor.textSecondary.opacity(0.25), lineWidth: 1)
        )
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .accessibilityIdentifier("code-block")
    }
}

/// Matrix `data-mx-spoiler` pill: hidden by default behind a reason label; tap toggles reveal/hide (TIMELINE FR-13, M20-10).
struct SpoilerPillView: View {
    let reason: String?
    let content: AttributedString
    @State private var isRevealed: Bool

    init(reason: String?, content: AttributedString, initiallyRevealed: Bool = false) {
        self.reason = reason
        self.content = content
        _isRevealed = State(initialValue: initiallyRevealed)
    }

    private var headerTitle: String {
        if let reason, !reason.isEmpty {
            return "Spoiler: \(reason)"
        }
        return "Spoiler"
    }

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            if isRevealed {
                VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                    HStack(spacing: HaloSpacing.xxs) {
                        Image(systemName: "eye")
                            .font(.caption2)
                        Text(headerTitle)
                            .font(HaloTypography.captionEmphasis)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(HaloColor.textSecondary)
                    Text(content)
                        .foregroundStyle(HaloColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HaloSpacing.s)
                .padding(.vertical, HaloSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HaloColor.bgPrimary.opacity(0.75), in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                        .strokeBorder(HaloColor.textSecondary.opacity(0.25), lineWidth: 1)
                )
            } else {
                HStack(spacing: HaloSpacing.xs) {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                    Text(headerTitle)
                        .font(HaloTypography.captionEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(HaloColor.textPrimary)
                .padding(.horizontal, HaloSpacing.s)
                .padding(.vertical, HaloSpacing.xs)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                        .strokeBorder(HaloColor.textSecondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? "\(headerTitle), revealed" : "\(headerTitle), hidden")
        .accessibilityHint(isRevealed ? "Double tap to hide" : "Double tap to reveal")
        .accessibilityIdentifier("spoiler-toggle")
    }
}

/// Safe horizontally-scrollable grid for Matrix HTML tables, bounded by `RichTextParser` caps (TIMELINE FR-13, M20-10).
struct SafeTableView: View {
    let table: RichTextDocument.Table

    private var columnCount: Int {
        max(table.headers.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        let grid = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !table.headers.isEmpty {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let cell = col < table.headers.count ? table.headers[col] : ""
                        Text(cell)
                            .font(HaloTypography.captionEmphasis)
                            .foregroundStyle(HaloColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 64, maxWidth: 200, alignment: .leading)
                            .padding(.horizontal, HaloSpacing.s)
                            .padding(.vertical, HaloSpacing.xs)
                    }
                }
                .background(HaloColor.bgSecondary)
                Divider()
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 { Divider() }
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let cell = col < row.count ? row[col] : ""
                        Text(cell)
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 64, maxWidth: 200, alignment: .leading)
                            .padding(.horizontal, HaloSpacing.s)
                            .padding(.vertical, HaloSpacing.xs)
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? HaloColor.bgPrimary.opacity(0.6) : HaloColor.bgSecondary.opacity(0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous)
                .strokeBorder(HaloColor.textSecondary.opacity(0.25), lineWidth: 1)
        )

        VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
            ViewThatFits(in: .horizontal) {
                grid
                ScrollView(.horizontal, showsIndicators: true) {
                    grid
                }
            }
            if table.truncated {
                Text("Table truncated")
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
            }
        }
        .accessibilityIdentifier("rich-text-table")
    }
}
#endif
