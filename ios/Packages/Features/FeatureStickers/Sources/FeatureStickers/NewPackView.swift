#if canImport(SwiftUI) && canImport(UIKit)
import HaloDomain
import PhotosUI
import SwiftUI

/// Create a personal sticker pack. Packs and their pictures are not encrypted (Matrix spec); the screen says so.
public struct NewPackView: View {
    let model: NewPackViewModel
    @State private var picked: [PhotosPickerItem] = []
    @Environment(\.dismiss) private var dismiss

    public init(model: NewPackViewModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            Form {
                nameSection
                picturesSection
                statusSection
            }
            .navigationTitle("New pack")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await model.create() } }.disabled(!model.canCreate) }
            }
            .onChange(of: picked) { _, items in load(items) }
            .onChange(of: model.phase) { _, phase in react(to: phase) }
        }
    }

    private var nameSection: some View {
        @Bindable var model = model
        return Section("Name") { TextField("Pack name", text: $model.name).accessibilityIdentifier("pack-name") }
    }

    private var picturesSection: some View {
        Section {
            PhotosPicker(selection: $picked, maxSelectionCount: 120, matching: .images) { Label("Add pictures", systemImage: "photo.badge.plus") }
            ForEach(model.items) { item in ItemRow(item: item, model: model) }
        } header: {
            Text("Stickers (\(model.items.count))")
        } footer: {
            Text("Pictures are shrunk to 512 px. Sticker packs are not end-to-end encrypted, even in encrypted rooms.")
        }
    }

    @ViewBuilder private var statusSection: some View {
        if case .uploading(let done, let total) = model.phase {
            Section { ProgressView("Uploading \(done) of \(total)…", value: Double(done), total: Double(total)) }
        }
        if case .failed(let message) = model.phase { Section { Text(message).foregroundStyle(.red) } }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) { model.add(data: data, filename: item.itemIdentifier ?? "sticker") }
            }
        }
    }

    private func react(to phase: NewPackViewModel.Phase) {
        switch phase {
        case .done: dismiss()
        case .failed: Task { try? await Task.sleep(for: .seconds(4)); model.dismissError() }
        default: break
        }
    }
}

private struct ItemRow: View {
    let item: NewPackViewModel.Item
    let model: NewPackViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: Binding(get: { item.shortcode }, set: { model.setShortcode($0, for: item) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let problem = model.problem(with: item) { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .swipeActions { Button("Remove", role: .destructive) { model.remove(item) } }
    }
}
#endif
