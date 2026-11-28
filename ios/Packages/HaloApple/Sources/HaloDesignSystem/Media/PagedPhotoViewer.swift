#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Photos)
import Photos
#endif

/// Item shown in Halo's single shared full-screen paged media viewer (ADR-0022 step 3, S9).
public struct PagedMediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let caption: String?
    public let fallbackSymbol: String
    public let isImage: Bool

    public init(id: String, title: String, caption: String? = nil, fallbackSymbol: String = "photo", isImage: Bool = true) {
        self.id = id
        self.title = title
        self.caption = caption
        self.fallbackSymbol = fallbackSymbol
        self.isImage = isImage
    }
}

/// Shared full-screen paged photo & media viewer used by both Timeline and Global Media Gallery (ADR-0022 step 3).
/// Supports VisionKit Live Text / Subject Lift / Visual Look Up, swipe-down dismiss, tap-to-hide chrome,
/// Save to Photos, Copy, Share, and optional Halo-native actions (Reply, React, Save as Sticker, Jump to Message).
/// Full-size photos are read and decoded straight from disk (M19-5) so viewing or swiping never holds whole files in memory.
public struct PagedPhotoViewer: View {
    private let items: [PagedMediaItem]
    @State private var currentID: String
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var showsChrome = true
    @State private var isZoomed = false
    @State private var dragOffset: CGFloat = 0
    @State private var loadedFileByID: [String: URL] = [:]
    @State private var isDismissed = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private let loadImageFile: @Sendable (PagedMediaItem) async -> URL?
    private let exportItem: @Sendable (PagedMediaItem) async -> URL?
    private let onJumpToMessage: ((PagedMediaItem) -> Void)?
    private let onReply: ((PagedMediaItem) -> Void)?
    private let onReact: ((PagedMediaItem, String) -> Void)?
    private let onSaveAsSticker: ((Data, String) -> Void)?

    private static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    public init(
        items: [PagedMediaItem],
        initialID: String,
        loadImageFile: @escaping @Sendable (PagedMediaItem) async -> URL?,
        exportItem: @escaping @Sendable (PagedMediaItem) async -> URL?,
        onJumpToMessage: ((PagedMediaItem) -> Void)? = nil,
        onReply: ((PagedMediaItem) -> Void)? = nil,
        onReact: ((PagedMediaItem, String) -> Void)? = nil,
        onSaveAsSticker: ((Data, String) -> Void)? = nil
    ) {
        self.items = items
        _currentID = State(initialValue: initialID)
        self.loadImageFile = loadImageFile
        self.exportItem = exportItem
        self.onJumpToMessage = onJumpToMessage
        self.onReply = onReply
        self.onReact = onReact
        self.onSaveAsSticker = onSaveAsSticker
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    private var currentItem: PagedMediaItem? {
        guard !items.isEmpty else { return nil }
        return items[currentIndex]
    }

    private var currentFileURL: URL? {
        guard let id = currentItem?.id else { return nil }
        return loadedFileByID[id]
    }

    private var dismissProgress: CGFloat {
        min(max(dragOffset / 240, 0), 1)
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                HaloColor.mediaBackdrop
                    .opacity(Double(1 - dismissProgress * 0.6))
                    .ignoresSafeArea()

                TabView(selection: $currentID) {
                    ForEach(items) { item in
                        PagedPhotoPage(
                            item: item,
                            existingFileURL: loadedFileByID[item.id],
                            loadImageFile: loadImageFile,
                            onLoaded: { url in
                                if isDismissed {
                                    Self.removeTemporaryFolder(of: url)
                                    return
                                }
                                if let previous = loadedFileByID[item.id], previous != url {
                                    Self.removeTemporaryFolder(of: previous)
                                }
                                loadedFileByID[item.id] = url
                            },
                            onSingleTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsChrome.toggle()
                                }
                            },
                            onZoomChange: { zoomed in
                                isZoomed = zoomed
                            }
                        )
                        .tag(item.id)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .offset(y: dragOffset)
                .scaleEffect(1 - dismissProgress * 0.12)
                .simultaneousGesture(swipeDownToDismissGesture)

                if let toastMessage {
                    Text(toastMessage)
                        .font(HaloTypography.caption.weight(.semibold))
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .padding(.horizontal, HaloSpacing.m)
                        .padding(.vertical, HaloSpacing.s)
                        .background(.ultraThinMaterial, in: .capsule)
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, showsChrome ? 92 : 36)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(2)
                }

                if showsChrome {
                    bottomChrome
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .navigationTitle(
                items.count > 1
                    ? "\(currentIndex + 1) of \(items.count)"
                    : (currentItem?.title ?? "Media")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(showsChrome ? .visible : .hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarVisibility(showsChrome ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!showsChrome)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("photo-viewer-done")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let currentItem, let onJumpToMessage {
                        Button {
                            dismiss()
                            onJumpToMessage(currentItem)
                        } label: {
                            Image(systemName: "arrow.uturn.right.circle")
                        }
                        .accessibilityLabel("Jump to message")
                    }
                    if let shareURL = exportedURL ?? currentFileURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share media")
                    } else if let currentItem {
                        Button {
                            let target = currentItem
                            isExporting = true
                            Task {
                                let url = await exportItem(target)
                                if isDismissed || currentID != target.id {
                                    if let url { Self.removeTemporaryFolder(of: url) }
                                } else {
                                    if let previous = exportedURL, previous != url {
                                        Self.removeTemporaryFolder(of: previous)
                                    }
                                    exportedURL = url
                                }
                                isExporting = false
                            }
                        } label: {
                            if isExporting {
                                ProgressView().tint(HaloColor.mediaOverlayForeground)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExporting)
                        .accessibilityLabel("Export media")
                    }
                    #if canImport(UIKit)
                    if currentItem?.isImage == true, currentFileURL != nil {
                        Menu {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                Task { await saveCurrentToPhotos() }
                            }
                            Button("Copy Photo", systemImage: "doc.on.doc") {
                                Task { await copyCurrentPhoto() }
                            }
                            if let onSaveAsSticker, let url = currentFileURL, let item = currentItem {
                                Divider()
                                Button("Save as Sticker", systemImage: "face.smiling") {
                                    if let data = try? Data(contentsOf: url) {
                                        onSaveAsSticker(data, item.caption ?? item.title)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More actions")
                    }
                    #endif
                }
            }
            .onChange(of: currentID) {
                if let url = exportedURL { Self.removeTemporaryFolder(of: url) }
                exportedURL = nil
                isExporting = false
                isZoomed = false
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            isDismissed = false
        }
        .onDisappear {
            isDismissed = true
            toastTask?.cancel()
            for url in loadedFileByID.values { Self.removeTemporaryFolder(of: url) }
            loadedFileByID.removeAll()
            if let url = exportedURL { Self.removeTemporaryFolder(of: url) }
            exportedURL = nil
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: HaloSpacing.s) {
            if let currentItem, currentItem.isImage || onReply != nil || onReact != nil {
                HStack(spacing: HaloSpacing.l) {
                    if let onReply {
                        Button {
                            dismiss()
                            onReply(currentItem)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.body.weight(.medium))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Reply")
                    }

                    if let onReact {
                        Menu {
                            ForEach(Self.quickReactions, id: \.self) { emoji in
                                Button(emoji) {
                                    onReact(currentItem, emoji)
                                    showToast("Reacted \(emoji)")
                                }
                            }
                        } label: {
                            Image(systemName: "face.smiling")
                                .font(.body.weight(.medium))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("React")
                    }

                    #if canImport(UIKit)
                    if currentItem.isImage, let url = currentFileURL {
                        Button {
                            Task { await saveCurrentToPhotos() }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.body.weight(.medium))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Save to Photos")

                        if let onSaveAsSticker {
                            Button {
                                if let data = try? Data(contentsOf: url) {
                                    onSaveAsSticker(data, currentItem.caption ?? currentItem.title)
                                }
                            } label: {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.body.weight(.medium))
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Save as Sticker")
                        }
                    }
                    #endif
                }
                .foregroundStyle(HaloColor.mediaOverlayForeground)
                .padding(.horizontal, HaloSpacing.m)
                .padding(.vertical, HaloSpacing.xxs)
                .background(.ultraThinMaterial, in: .capsule)
                .environment(\.colorScheme, .dark)
            }

            if let caption = currentItem?.caption, !caption.isEmpty {
                Text(caption)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HaloSpacing.l)
                    .padding(.vertical, HaloSpacing.s)
                    .frame(maxWidth: .infinity)
                    .background(HaloColor.mediaOverlayBackground)
            }
        }
    }

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                guard value.translation.height > 0, value.translation.height > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard !isZoomed else {
                    dragOffset = 0
                    return
                }
                let shouldDismiss = value.translation.height > 110 || value.predictedEndTranslation.height > 320
                if shouldDismiss && value.translation.height > abs(value.translation.width) {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    #if canImport(UIKit)
    private func copyCurrentPhoto() async {
        guard let url = currentFileURL,
              let image = await ImagePipeline.decode(fileURL: url, maxPixel: ImagePipeline.Size.viewer) else { return }
        UIPasteboard.general.image = image
        showToast("Copied")
    }

    private func saveCurrentToPhotos() async {
        guard let url = currentFileURL else { return }
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showToast("Allow Photos access in Settings")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }
            showToast("Saved to Photos")
        } catch {
            showToast("Couldn't save photo")
        }
        #endif
    }
    #endif

    nonisolated public static func removeTemporaryFolder(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let name = folder.lastPathComponent
        guard name.hasPrefix("halo-viewer-")
            || name.hasPrefix("halo-photo-")
            || name.hasPrefix("halo-global-gallery-")
            || name.hasPrefix("halo-gallery-")
        else { return }
        try? FileManager.default.removeItem(at: folder)  // best-effort: temporary viewer/gallery copy
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }
}

private struct PagedPhotoPage: View {
    let item: PagedMediaItem
    let existingFileURL: URL?
    let loadImageFile: @Sendable (PagedMediaItem) async -> URL?
    let onLoaded: @MainActor (URL) -> Void
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @State private var fileURL: URL?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reloadToken = 0
    #if canImport(UIKit)
    /// The photo decoded off the main thread straight from disk, at most `ImagePipeline.Size.viewer` on the long side.
    @State private var viewerImage: UIImage?
    #endif

    private struct LoadKey: Equatable {
        let id: String
        let token: Int
    }

    var body: some View {
        Group {
            #if canImport(UIKit)
            if item.isImage {
                if let image = viewerImage {
                    ZoomableImageView(
                        image: image,
                        onSingleTap: onSingleTap,
                        onZoomChange: onZoomChange
                    )
                } else if isLoading {
                    ProgressView()
                        .tint(HaloColor.mediaOverlayForeground)
                        .accessibilityLabel("Loading photo")
                } else if loadFailed {
                    errorView
                } else {
                    fallbackView
                }
            } else {
                fallbackView
            }
            #else
            fallbackView
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: LoadKey(id: item.id, token: reloadToken)) {
            guard item.isImage else { return }
            loadFailed = false
            if let cachedURL = fileURL ?? existingFileURL {
                fileURL = cachedURL
                #if canImport(UIKit)
                if viewerImage == nil {
                    isLoading = true
                    viewerImage = await ImagePipeline.decode(fileURL: cachedURL, maxPixel: ImagePipeline.Size.viewer)
                    loadFailed = viewerImage == nil
                    isLoading = false
                }
                #endif
                return
            }
            isLoading = true
            let loaded = await loadImageFile(item)
            if Task.isCancelled {
                if let loaded { PagedPhotoViewer.removeTemporaryFolder(of: loaded) }
                isLoading = false
                return
            }
            fileURL = loaded
            if let loaded {
                onLoaded(loaded)
                #if canImport(UIKit)
                viewerImage = await ImagePipeline.decode(fileURL: loaded, maxPixel: ImagePipeline.Size.viewer)
                loadFailed = viewerImage == nil
                #endif
            } else {
                loadFailed = true
            }
            isLoading = false
        }
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label("Couldn't load photo", systemImage: "exclamationmark.triangle")
                .foregroundStyle(HaloColor.mediaOverlayForeground)
        } description: {
            Text("Check your connection and try again.")
                .foregroundStyle(HaloColor.mediaOverlayForeground.opacity(0.8))
        } actions: {
            Button("Try again") {
                reloadToken += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(HaloSpacing.l)
        .contentShape(.rect)
        .onTapGesture(perform: onSingleTap)
    }

    private var fallbackView: some View {
        VStack(spacing: HaloSpacing.m) {
            Image(systemName: item.fallbackSymbol)
                .font(.largeTitle)
                .foregroundStyle(HaloColor.mediaOverlayForeground.opacity(0.85))
            Text(item.title)
                .font(HaloTypography.headline)
                .foregroundStyle(HaloColor.mediaOverlayForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HaloSpacing.l)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onSingleTap)
    }
}
#endif
