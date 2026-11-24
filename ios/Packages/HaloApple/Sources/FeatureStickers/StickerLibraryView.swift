#if canImport(SwiftUI) && canImport(UIKit)
import HaloDesignSystem
import HaloDomain
import PhotosUI
import SwiftUI

/// Full sticker pack manager: visual pack cards with sticker previews, create/rename/delete packs, and drill-in pack editor.
public struct StickerLibraryView: View {
    @State private var model: StickerLibraryViewModel
    @State private var newPack: NewPackViewModel?
    @State private var renamingPack: StickerPack?
    @State private var renameDraft = ""
    @State private var deletingPack: StickerPack?
    @State private var addingToPack: StickerPack?
    @State private var pickedItems: [PhotosPickerItem] = []

    public init(model: StickerLibraryViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if let error = model.error {
                Section {
                    HStack(spacing: HaloSpacing.s) {
                        Text(error).font(HaloTypography.caption).foregroundStyle(HaloColor.danger)
                        Spacer()
                        Button { model.dismissError() } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                    }
                }
            }

            if let progress = model.uploadProgress {
                Section {
                    ProgressView(
                        "Adding \(progress.done) of \(progress.total)…",
                        value: Double(progress.done),
                        total: Double(max(progress.total, 1))
                    )
                }
            }

            if model.unavailableCount > 0 {
                Section {
                    HStack(spacing: HaloSpacing.s) {
                        Text("\(model.unavailableCount) unavailable \(model.unavailableCount == 1 ? "pack" : "packs")")
                            .font(HaloTypography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { Task { await model.removeUnavailablePacks() } }
                            .font(HaloTypography.caption.weight(.semibold))
                    }
                }
            }

            if model.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading sticker packs…")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if model.packs.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No sticker packs yet", systemImage: "face.smiling")
                    } description: {
                        Text("Create a pack from your photos to send stickers in any chat.")
                    } actions: {
                        if model.canCreatePack {
                            Button("New sticker pack") { newPack = model.beginNewPack() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(model.packs) { pack in
                        NavigationLink {
                            StickerPackDetailView(ref: pack.ref, model: model)
                        } label: {
                            StickerPackRowCard(pack: pack, model: model)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { beginRename(pack) }
                            Button("Add stickers", systemImage: "photo.badge.plus") { addingToPack = pack }
                            Divider()
                            Button("Delete pack", systemImage: "trash", role: .destructive) { deletingPack = pack }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { deletingPack = pack }
                            Button("Rename") { beginRename(pack) }.tint(HaloColor.accent)
                        }
                    }
                } footer: {
                    Text("Sticker packs and their images are not end-to-end encrypted, even when sent in encrypted rooms.")
                }
            }
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Stickers")
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, HaloSpacing.m)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            if model.canCreatePack {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newPack = model.beginNewPack()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New sticker pack")
                    .accessibilityIdentifier("new-sticker-pack")
                    .disabled(model.isBusy)
                }
            }
        }
        .refreshable { await model.reload() }
        .sheet(item: $newPack) { NewPackView(model: $0) }
        .photosPicker(
            isPresented: Binding(get: { addingToPack != nil }, set: { if !$0 { addingToPack = nil } }),
            selection: $pickedItems,
            maxSelectionCount: max(1, ImagePackBuilder.maximumImages - (addingToPack?.stickers.count ?? 0)),
            matching: .images
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty, let target = addingToPack else { return }
            pickedItems = []
            addingToPack = nil
            Task { await importPicked(items, into: target.ref) }
        }
        .alert("Rename pack", isPresented: Binding(get: { renamingPack != nil }, set: { if !$0 { renamingPack = nil } })) {
            TextField("Pack name", text: $renameDraft)
            Button("Save") {
                guard let pack = renamingPack else { return }
                let draft = renameDraft
                renamingPack = nil
                Task { await model.rename(pack.ref, to: draft) }
            }
            Button("Cancel", role: .cancel) { renamingPack = nil }
        }
        .alert(
            "Delete \"\(deletingPack?.displayName ?? "pack")\"?",
            isPresented: Binding(get: { deletingPack != nil }, set: { if !$0 { deletingPack = nil } })
        ) {
            Button("Delete pack", role: .destructive) {
                guard let pack = deletingPack else { return }
                deletingPack = nil
                Task { await model.deletePack(pack.ref) }
            }
            Button("Cancel", role: .cancel) { deletingPack = nil }
        } message: {
            Text("This removes the pack from your library. Personal packs you created will be permanently deleted.")
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private func beginRename(_ pack: StickerPack) {
        renameDraft = pack.displayName
        renamingPack = pack
    }

    private func importPicked(_ items: [PhotosPickerItem], into ref: PackRef) async {
        var files: [(data: Data, filename: String)] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                files.append((data: data, filename: item.itemIdentifier ?? "sticker"))
            }
        }
        if !files.isEmpty {
            await model.addStickers(to: ref, files: files)
        }
    }
}

/// A rich pack row showing the pack name, count, and a horizontal strip of sticker thumbnails.
private struct StickerPackRowCard: View {
    let pack: StickerPack
    let model: StickerLibraryViewModel
    private let previewLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(pack.displayName)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: HaloSpacing.s)
                Text("\(pack.stickers.count) \(pack.stickers.count == 1 ? "sticker" : "stickers")")
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
            }

            if pack.stickers.isEmpty {
                Text("Empty pack — tap to add stickers")
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
                    .padding(.vertical, HaloSpacing.xs)
            } else {
                HStack(spacing: HaloSpacing.s) {
                    ForEach(pack.stickers.prefix(previewLimit)) { sticker in
                        StickerThumbnailTile(sticker: sticker, model: model, size: 52)
                    }
                    if pack.stickers.count > previewLimit {
                        let overflow = pack.stickers.count - previewLimit
                        Text("+\(overflow)")
                            .font(HaloTypography.caption.weight(.semibold))
                            .foregroundStyle(HaloColor.textSecondary)
                            .frame(width: 52, height: 52)
                            .background(HaloColor.bgSecondary, in: .rect(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(.vertical, HaloSpacing.xs)
    }
}

/// Full single-pack editor: rename pack, add stickers via PhotosPicker, preview stickers, delete individual stickers, or delete the whole pack.
public struct StickerPackDetailView: View {
    let ref: PackRef
    let model: StickerLibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var confirmingDeletePack = false
    @State private var previewingSticker: Sticker?

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: HaloSpacing.s)]

    private var pack: StickerPack? { model.pack(for: ref) }

    public var body: some View {
        Group {
            if let pack {
                ScrollView {
                    VStack(alignment: .leading, spacing: HaloSpacing.m) {
                        if let error = model.error {
                            HStack(spacing: HaloSpacing.s) {
                                Text(error).font(HaloTypography.caption).foregroundStyle(HaloColor.danger)
                                Spacer()
                                Button { model.dismissError() } label: {
                                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(HaloSpacing.s)
                            .background(HaloColor.bgSecondary, in: .rect(cornerRadius: 10))
                        }

                        if let progress = model.uploadProgress {
                            ProgressView(
                                "Adding \(progress.done) of \(progress.total)…",
                                value: Double(progress.done),
                                total: Double(max(progress.total, 1))
                            )
                            .padding(HaloSpacing.s)
                            .background(HaloColor.bgSecondary, in: .rect(cornerRadius: 10))
                        }

                        if pack.stickers.isEmpty {
                            ContentUnavailableView {
                                Label("No stickers in this pack", systemImage: "face.smiling")
                            } description: {
                                Text("Add photos to populate this sticker pack.")
                            } actions: {
                                PhotosPicker(
                                    selection: $pickedItems,
                                    maxSelectionCount: ImagePackBuilder.maximumImages,
                                    matching: .images
                                ) {
                                    Label("Add stickers", systemImage: "photo.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isBusy)
                            }
                            .padding(.top, HaloSpacing.xl)
                        } else {
                            HStack {
                                Text("\(pack.stickers.count) \(pack.stickers.count == 1 ? "sticker" : "stickers")")
                                    .font(HaloTypography.caption)
                                    .foregroundStyle(HaloColor.textSecondary)
                                Spacer()
                                if isEditing {
                                    Text("Tap a sticker to remove it")
                                        .font(HaloTypography.caption)
                                        .foregroundStyle(HaloColor.textSecondary)
                                }
                            }

                            LazyVGrid(columns: columns, spacing: HaloSpacing.m) {
                                ForEach(pack.stickers) { sticker in
                                    VStack(spacing: HaloSpacing.xxs) {
                                        ZStack(alignment: .topTrailing) {
                                            Button {
                                                if isEditing {
                                                    Task { await model.removeSticker(shortcode: sticker.shortcode, from: ref) }
                                                } else {
                                                    previewingSticker = sticker
                                                }
                                            } label: {
                                                StickerThumbnailTile(sticker: sticker, model: model, size: 80)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(model.isBusy)

                                            if isEditing {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.title3)
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(HaloColor.onAccent, HaloColor.danger)
                                                    .offset(x: 6, y: -6)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                        Text(sticker.shortcode)
                                            .font(HaloTypography.caption)
                                            .foregroundStyle(HaloColor.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .contextMenu {
                                        Button("Delete sticker", systemImage: "trash", role: .destructive) {
                                            Task { await model.removeSticker(shortcode: sticker.shortcode, from: ref) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(HaloSpacing.m)
                }
                .scrollEdgeEffectHidden(true, for: .top)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(pack.displayName)
                            .font(HaloTypography.headline)
                            .foregroundStyle(HaloColor.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, HaloSpacing.m)
                            .frame(height: 44)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItemGroup(placement: .primaryAction) {
                        if isEditing {
                            Button("Done") { isEditing = false }
                                .fontWeight(.semibold)
                        } else {
                            let remaining = max(0, ImagePackBuilder.maximumImages - pack.stickers.count)
                            if remaining > 0 {
                                PhotosPicker(
                                    selection: $pickedItems,
                                    maxSelectionCount: remaining,
                                    matching: .images
                                ) {
                                    Image(systemName: "plus")
                                }
                                .accessibilityLabel("Add stickers")
                                .disabled(model.isBusy)
                            }
                            Menu {
                                Button("Rename pack", systemImage: "pencil") {
                                    renameDraft = pack.displayName
                                    showingRename = true
                                }
                                if !pack.stickers.isEmpty {
                                    Button("Remove stickers", systemImage: "minus.circle") {
                                        isEditing = true
                                    }
                                }
                                Divider()
                                Button("Delete pack", systemImage: "trash", role: .destructive) {
                                    confirmingDeletePack = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("Pack options")
                            .disabled(model.isBusy)
                        }
                    }
                }
                .onChange(of: pickedItems) { _, items in
                    guard !items.isEmpty else { return }
                    pickedItems = []
                    Task { await importPicked(items) }
                }
                .alert("Rename pack", isPresented: $showingRename) {
                    TextField("Pack name", text: $renameDraft)
                    Button("Save") {
                        let draft = renameDraft
                        Task { await model.rename(ref, to: draft) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Delete \"\(pack.displayName)\"?", isPresented: $confirmingDeletePack) {
                    Button("Delete pack", role: .destructive) {
                        Task {
                            if await model.deletePack(ref) {
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the pack from your library. Personal packs you created will be permanently deleted.")
                }
                .sheet(item: $previewingSticker) { sticker in
                    StickerDetailPreviewSheet(sticker: sticker, model: model) {
                        previewingSticker = nil
                        Task { await model.removeSticker(shortcode: sticker.shortcode, from: ref) }
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            } else {
                ContentUnavailableView("Pack unavailable", systemImage: "face.smiling")
            }
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        var files: [(data: Data, filename: String)] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                files.append((data: data, filename: item.itemIdentifier ?? "sticker"))
            }
        }
        if !files.isEmpty {
            await model.addStickers(to: ref, files: files)
        }
    }
}

private struct StickerThumbnailTile: View {
    let sticker: Sticker
    let model: StickerLibraryViewModel
    let size: CGFloat
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Text(sticker.shortcode)
                    .font(.caption2)
                    .foregroundStyle(HaloColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .background(HaloColor.bgSecondary, in: .rect(cornerRadius: 10))
        .task(id: sticker.id) {
            data = await model.thumbnail(for: sticker)
        }
    }
}

private struct StickerDetailPreviewSheet: View {
    let sticker: Sticker
    let model: StickerLibraryViewModel
    let onDelete: () -> Void
    @State private var data: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: HaloSpacing.l) {
                Group {
                    if let data {
                        AnimatedStickerView(data: data)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 200, height: 200)
                .background(HaloColor.bgSecondary, in: .rect(cornerRadius: 16))

                Text(":\(sticker.shortcode):")
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete sticker", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(HaloColor.danger)
                .padding(.horizontal, HaloSpacing.l)
            }
            .padding(.vertical, HaloSpacing.m)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: sticker.id) {
                if let full = await model.fullImage(for: sticker) {
                    data = full
                } else {
                    data = await model.thumbnail(for: sticker)
                }
            }
        }
    }
}
#endif
