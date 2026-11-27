#if canImport(SwiftUI) && canImport(UIKit)
import HaloDesignSystem
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
            .onChange(of: model.phase) { _, phase in if case .done = phase { dismiss() } }
        }
        .interactiveDismissDisabled(model.isBusy)
    }

    private var nameSection: some View {
        @Bindable var model = model
        return Section("Name") { TextField("Pack name", text: $model.name).accessibilityIdentifier("pack-name") }
    }

    private var picturesSection: some View {
        Section {
            PhotosPicker(selection: $picked, maxSelectionCount: 120, matching: .images) {
                Label("Add pictures", systemImage: "photo.badge.plus")
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        if case .failed(let message) = model.phase {
            Section {
                HStack(spacing: 10) {
                    Text(message).foregroundStyle(HaloColor.danger)
                    Spacer()
                    Button { model.dismissError() } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
            }
        }
    }

    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) { model.add(data: data, filename: item.itemIdentifier ?? "sticker") }  // best-effort: an item the picker can't read is skipped
            }
        }
    }
}

private struct ItemRow: View {
    let item: NewPackViewModel.Item
    let model: NewPackViewModel
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.15))
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Shortcode", text: Binding(get: { item.shortcode }, set: { model.setShortcode($0, for: item) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let problem = model.problem(with: item) { Text(problem).font(HaloTypography.caption).foregroundStyle(HaloColor.danger) }
            }
        }
        .task(id: item.id) { thumbnail = await Self.makeThumbnail(item.data) }
        .swipeActions { Button("Remove", role: .destructive) { model.remove(item) } }
    }

    /// Decodes a small thumbnail off the main actor once per picked photo, so typing shortcodes never re-decodes full images.
    @concurrent private static func makeThumbnail(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }  // decode: off the main actor (@concurrent), once per picked photo
        return image.preparingThumbnail(of: CGSize(width: 88, height: 88)) ?? image
    }
}
#endif
