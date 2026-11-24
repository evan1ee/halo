#if canImport(SwiftUI) && canImport(UIKit)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// Lightweight sheet presented from the full-screen photo viewer to save an image straight into an existing (or new) sticker pack.
public struct AddToStickerPackSheet: View {
    @State private var model: StickerLibraryViewModel
    private let imageData: Data
    private let filename: String
    @State private var newPack: NewPackViewModel?
    @State private var savedPackName: String?
    @Environment(\.dismiss) private var dismiss

    public init(model: StickerLibraryViewModel, imageData: Data, filename: String) {
        _model = State(initialValue: model)
        self.imageData = imageData
        self.filename = filename
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error = model.error {
                    Section {
                        Text(error)
                            .font(HaloTypography.caption)
                            .foregroundStyle(HaloColor.danger)
                    }
                }

                if let savedPackName {
                    Section {
                        Label("Added to \(savedPackName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(HaloColor.accent)
                    }
                }

                if model.isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading packs…")
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(model.packs) { pack in
                            Button {
                                Task {
                                    if await model.addStickers(to: pack.ref, files: [(data: imageData, filename: filename)]) {
                                        savedPackName = pack.displayName
                                        try? await Task.sleep(for: .milliseconds(700))
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.displayName)
                                            .font(HaloTypography.headline)
                                            .foregroundStyle(HaloColor.textPrimary)
                                        Text("\(pack.stickers.count) \(pack.stickers.count == 1 ? "sticker" : "stickers")")
                                            .font(HaloTypography.caption)
                                            .foregroundStyle(HaloColor.textSecondary)
                                    }
                                    Spacer()
                                    if model.isBusy {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(HaloColor.accent)
                                    }
                                }
                            }
                            .disabled(model.isBusy || pack.stickers.count >= ImagePackBuilder.maximumImages)
                        }

                        if model.canCreatePack {
                            Button {
                                if let vm = model.beginNewPack() {
                                    vm.add(data: imageData, filename: filename)
                                    newPack = vm
                                }
                            } label: {
                                Label("Create new pack…", systemImage: "folder.badge.plus")
                            }
                            .disabled(model.isBusy)
                        }
                    } header: {
                        Text("Choose a pack")
                    } footer: {
                        Text("Images are resized to 512 px. Sticker packs are not end-to-end encrypted.")
                    }
                }
            }
            .navigationTitle("Save as Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $newPack, onDismiss: {
                if savedPackName == nil && !model.packs.isEmpty { dismiss() }
            }) { NewPackView(model: $0) }
            .task { await model.start() }
            .onDisappear { model.stop() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
