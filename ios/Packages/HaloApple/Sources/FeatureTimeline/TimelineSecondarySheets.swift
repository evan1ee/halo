#if canImport(SwiftUI)
import HaloBotRendering
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ReactionPicker: View {
    let model: TimelineViewModel

    var body: some View {
        NativeEmojiPicker(
            recents: model.recentEmoji,
            onPick: { key in Task { await model.pickReaction(key) } }
        )
        .accessibilityIdentifier("reactionPicker")
    }
}

/// Reusable native emoji picker supporting:
/// 1. Direct input from the iOS system Emoji keyboard (any Unicode emoji, skin tone, flag, or new iOS emoji),
/// 2. Recently used emoji, and
/// 3. Searchable categorised Unicode emoji grid.
struct NativeEmojiPicker: View {
    let recents: [String]
    let onPick: (String) -> Void
    @State private var search = ""

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible()), count: 8) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search emoji", text: $search)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("emoji-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))

                #if canImport(UIKit)
                NativeEmojiKeyboardField(placeholder: "😀+") { emoji in
                    onPick(emoji)
                }
                .frame(width: 64, height: 36)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier("emoji-keyboard-input")
                #endif
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !recents.isEmpty {
                            sectionHeader("Recent")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(recents, id: \.self) { emoji in
                                    emojiButton(emoji)
                                }
                            }
                        }
                        ForEach(NativeEmoji.Category.allCases) { category in
                            let items = NativeEmoji.catalog.filter { $0.category == category }
                            if !items.isEmpty {
                                sectionHeader(category.rawValue)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(items) { entry in
                                        emojiButton(entry.emoji)
                                    }
                                }
                            }
                        }
                    } else {
                        let hits = NativeEmoji.search(search)
                        if hits.isEmpty {
                            if let direct = NativeEmoji.firstEmoji(in: search) {
                                sectionHeader("Use emoji")
                                emojiButton(direct)
                            } else {
                                Text("No matching emoji. Tap 😀+ to use the iOS emoji keyboard.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 12)
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(hits) { entry in
                                    emojiButton(entry.emoji)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func emojiButton(_ emoji: String) -> some View {
        Button(emoji) { onPick(emoji) }
            .font(.title2)
            .buttonStyle(.plain)
    }
}

#if canImport(UIKit)
/// A `UITextField` subclass that prefers the iOS system Emoji keyboard (`primaryLanguage == "emoji"`)
/// and emits every native emoji grapheme cluster typed into it.
private final class EmojiUITextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

private struct NativeEmojiKeyboardField: UIViewRepresentable {
    let placeholder: String
    let onEmoji: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEmoji: onEmoji) }

    func makeUIView(context: Context) -> EmojiUITextField {
        let field = EmojiUITextField()
        field.placeholder = placeholder
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 18)
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: EmojiUITextField, context: Context) {
        context.coordinator.onEmoji = onEmoji
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onEmoji: (String) -> Void
        init(onEmoji: @escaping (String) -> Void) { self.onEmoji = onEmoji }

        @objc func textChanged(_ sender: UITextField) {
            guard let text = sender.text, !text.isEmpty else { return }
            if let emoji = NativeEmoji.firstEmoji(in: text) {
                sender.text = ""
                onEmoji(emoji)
            } else {
                sender.text = ""
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
#endif

/// A file, audio or video attachment: icon, name and details; tapping downloads it and opens Quick Look (which plays audio and
/// video and offers sharing and saving).

struct EditHistoryView: View {
    let state: TimelineViewModel.EditHistoryState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    LoadingState(.rows(count: 3))
                        .padding(.horizontal, HaloSpacing.l)
                case .failed(let text):
                    ErrorState(
                        icon: "clock.badge.exclamationmark",
                        title: "Edit history unavailable",
                        message: text
                    )
                case .loaded(let versions) where versions.isEmpty:
                    EmptyState(
                        icon: "clock",
                        title: "No edits yet",
                        message: "Previous versions of this message will appear here."
                    )
                case .loaded(let versions):
                    List(versions) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.text.isEmpty ? "(no text)" : version.text)
                            Text([version.isCurrent ? "Current" : nil, version.time].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MessageSourceView: View {
    let source: TimelineRow.Source
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if let sender = source.sender { LabeledContent("Sender", value: sender) }
                if let eventID = source.eventID { LabeledContent("Event", value: eventID) }
                Section("Body") { Text(source.body).textSelection(.enabled) }
                if let formatted = source.formattedBody {
                    Section("Formatted body (HTML)") { Text(formatted).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
                #if canImport(UIKit)
                Section {
                    Button {
                        UIPasteboard.general.string = source.formattedText
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy source", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyMessageSource")
                }
                #endif
            }
            .navigationTitle("Message source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ShareLink(item: source.formattedText) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

/// A bot message as a native card (BOT_MESSAGES FR-2). Read-only: ticking tasks needs the interaction protocol (FR-3).
#endif
