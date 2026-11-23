#if canImport(UIKit)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// The attachment panel's Article tab (docs/features/COMPOSER_PANELS.md §7a, D101): opens the Markdown editor.
struct ArticleTab: View {
    let model: TimelineViewModel
    let input: ComposerInputController
    @State private var composing = false

    var body: some View {
        VStack(spacing: HaloSpacing.m) {
            Spacer(minLength: HaloSpacing.s)
            Image(systemName: "doc.richtext")
                .font(HaloTypography.title)
                .imageScale(.large)
                .foregroundStyle(HaloColor.accent)
                .accessibilityHidden(true)
            Text("Write an article")
                .font(HaloTypography.headline)
                .foregroundStyle(HaloColor.textPrimary)
            Text("A longer message with headings, lists, quotes, links and code, written in Markdown.")
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { composing = true } label: {
                Label(model.articleDraft.isEmpty ? "New article" : "Continue article", systemImage: "square.and.pencil")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("write-article-button")
            Spacer(minLength: 72)
        }
        .padding(.horizontal, HaloSpacing.l)
        .fullScreenCover(isPresented: $composing) {
            ArticleComposer(model: model) { input.dismiss() }
        }
    }
}

/// Full-screen Markdown editor with a formatting bar and a preview. The text lives in `model.articleDraft`, so closing
/// the editor keeps it; Send goes through the ordinary text path.
struct ArticleComposer: View {
    enum Mode: String, Hashable { case write, preview }

    @Bindable var model: TimelineViewModel
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.write
    @State private var selection: TextSelection?
    @State private var sending = false
    @FocusState private var editorFocused: Bool

    private var count: Int { model.articleDraft.count }
    private var tooLong: Bool { count > ArticleMarkdown.maximumLength }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    Text("Write").tag(Mode.write)
                    Text("Preview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, HaloSpacing.l)
                .padding(.vertical, HaloSpacing.s)
                .accessibilityIdentifier("article-mode")

                switch mode {
                case .write: editor
                case .preview: ArticlePreview(markdown: model.articleDraft)
                }

                if let error = model.sendError, !sending {
                    Text(error)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                        .padding(HaloSpacing.s)
                        .accessibilityIdentifier("article-error")
                }
            }
            .background(HaloColor.bgPrimary)
            .navigationTitle("Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("article-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!ArticleMarkdown.canSend(model.articleDraft) || sending)
                        .accessibilityIdentifier("article-send")
                }
            }
            .onAppear { if mode == .write { editorFocused = true } }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.articleDraft, selection: $selection)
                    .font(HaloTypography.code)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(.horizontal, HaloSpacing.m)
                    .accessibilityIdentifier("article-editor")
                if model.articleDraft.isEmpty {
                    Text("# Title\n\nWrite in Markdown: **bold**, _italic_, `code`, [links](https://), lists and > quotes.")
                        .font(HaloTypography.code)
                        .foregroundStyle(HaloColor.textSecondary)
                        .padding(.horizontal, HaloSpacing.m + 5)
                        .padding(.vertical, HaloSpacing.s)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            formattingBar
        }
    }

    private var formattingBar: some View {
        HStack(spacing: HaloSpacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HaloSpacing.xs) {
                    ForEach(Self.buttons, id: \.format) { item in
                        Button { apply(item.format) } label: {
                            Image(systemName: item.systemImage)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(HaloColor.textPrimary)
                        .accessibilityLabel(item.label)
                        .accessibilityIdentifier("article-format-\(item.format.rawValue)")
                    }
                }
                .padding(.horizontal, HaloSpacing.s)
            }
            Text("\(count.formatted())")
                .font(HaloTypography.codeMeta)
                .foregroundStyle(tooLong ? HaloColor.danger : HaloColor.textSecondary)
                .padding(.trailing, HaloSpacing.m)
                .accessibilityLabel(tooLong ? "\(count) characters, too long" : "\(count) characters")
        }
        .background(HaloColor.bgSecondary)
    }

    private static let buttons: [(format: ArticleMarkdown.Format, systemImage: String, label: String)] = [
        (.heading, "textformat.size", "Heading"),
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.strikethrough, "strikethrough", "Strikethrough"),
        (.link, "link", "Link"),
        (.bulletList, "list.bullet", "Bulleted list"),
        (.numberedList, "list.number", "Numbered list"),
        (.quote, "text.quote", "Quote"),
        (.code, "chevron.left.forwardslash.chevron.right", "Inline code"),
        (.codeBlock, "curlybraces", "Code block"),
    ]

    /// Runs a formatting-bar action on the editor's selection (the end of the text when there is none).
    private func apply(_ format: ArticleMarkdown.Format) {
        let text = model.articleDraft
        var range = text.count..<text.count
        if case .selection(let indices)? = selection?.indices,
           indices.lowerBound >= text.startIndex, indices.upperBound <= text.endIndex {
            range = text.distance(from: text.startIndex, to: indices.lowerBound)..<text.distance(from: text.startIndex, to: indices.upperBound)
        }
        let result = ArticleMarkdown.apply(format, to: text, selection: range)
        model.articleDraft = result.text
        let new = result.text
        let lower = new.index(new.startIndex, offsetBy: result.selection.lowerBound)
        let upper = new.index(new.startIndex, offsetBy: result.selection.upperBound)
        selection = TextSelection(range: lower..<upper)
        editorFocused = true
    }

    private func send() {
        sending = true
        Task {
            if await model.sendArticle() {
                dismiss()
                onSent()
            }
            sending = false
        }
    }
}

/// The article as Halo will show it: block layout from `ArticleMarkdown.blocks`, inline Markdown styled by Foundation.
struct ArticlePreview: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HaloSpacing.m) {
                let blocks = ArticleMarkdown.blocks(markdown)
                if blocks.isEmpty {
                    Text("Nothing to preview yet.")
                        .font(HaloTypography.body)
                        .foregroundStyle(HaloColor.textSecondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HaloSpacing.l)
        }
        .accessibilityIdentifier("article-preview")
    }

    @ViewBuilder
    private func view(for block: ArticleMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? HaloTypography.title : level == 2 ? HaloTypography.headline : HaloTypography.bodyEmphasis)
                .foregroundStyle(HaloColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text)).font(HaloTypography.body).foregroundStyle(HaloColor.textPrimary)
        case .bullet(let text):
            listItem(marker: "•", text: text)
        case .numbered(let number, let text):
            listItem(marker: "\(number).", text: text)
        case .quote(let text):
            HStack(spacing: HaloSpacing.s) {
                Capsule().fill(HaloColor.accent).frame(width: 3)
                Text(Self.inline(text)).font(HaloTypography.body).foregroundStyle(HaloColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(HaloTypography.code).foregroundStyle(HaloColor.textPrimary).padding(HaloSpacing.m)
            }
            .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium))
        case .rule:
            Divider()
        }
    }

    private func listItem(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.s) {
            Text(marker).font(HaloTypography.body).foregroundStyle(HaloColor.textSecondary)
            Text(Self.inline(text)).font(HaloTypography.body).foregroundStyle(HaloColor.textPrimary)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
#endif
