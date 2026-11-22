#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// "Send to…": what another app shared, and the chats to send it to (M16 share extension).
public struct ShareTargetPickerView: View {
    public struct Target: Identifiable, Equatable {
        public let id: RoomID
        public let name: String
        public init(id: RoomID, name: String) {
            self.id = id
            self.name = name
        }
    }

    private let model: ShareHandoffViewModel
    private let targets: [Target]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    public init(model: ShareHandoffViewModel, targets: [Target]) {
        self.model = model
        self.targets = targets
    }

    private var filtered: [Target] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? targets : targets.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    public var body: some View {
        NavigationStack {
            List {
                if let payload = model.current {
                    Section("Sharing") {
                        ForEach(payload.items) { item in
                            Label(item.summary, systemImage: Self.symbol(for: item.kind))
                                .lineLimit(2)
                        }
                    }
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(HaloColor.danger).accessibilityIdentifier("shareError") }
                }
                Section("Send to") {
                    ForEach(filtered) { target in
                        Button { Task { await model.send(to: target.id) } } label: { Text(target.name) }
                            .disabled(model.isSending)
                    }
                    if filtered.isEmpty {
                        Text("No chats match.").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Send to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { Task { await model.discard() } }
                        .disabled(model.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending { ProgressView() } else { Button("Later") { dismiss() } }
                }
            }
            .interactiveDismissDisabled(model.isSending)
        }
        .accessibilityIdentifier("shareTargetPicker")
    }

    private static func symbol(for kind: SharedItem.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
#endif
