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
public struct PagedPhotoViewer: View {
    private let items: [PagedMediaItem]
    @State private var currentID: String
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var showsChrome = true
    @State private var isZoomed = false
    @State private var dragOffset: CGFloat = 0
    @State private var loadedDataByID: [String: Data] = [:]
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private let loadImageData: @Sendable (PagedMediaItem) async -> Data?
    private let exportItem: @Sendable (PagedMediaItem) async -> URL?
    private let onJumpToMessage: ((PagedMediaItem) -> Void)?
    private let onReply: ((PagedMediaItem) -> Void)?
    private let onReact: ((PagedMediaItem, String) -> Void)?
    private let onSaveAsSticker: ((Data, String) -> Void)?

    private static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    public init(
        items: [PagedMediaItem],
        initialID: String,
        loadImageData: @escaping @Sendable (PagedMediaItem) async -> Data?,
        exportItem: @escaping @Sendable (PagedMediaItem) async -> URL?,
        onJumpToMessage: ((PagedMediaItem) -> Void)? = nil,
        onReply: ((PagedMediaItem) -> Void)? = nil,
        onReact: ((PagedMediaItem, String) -> Void)? = nil,
        onSaveAsSticker: ((Data, String) -> Void)? = nil
    ) {
        self.items = items
        _currentID = State(initialValue: initialID)
        self.loadImageData = loadImageData
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

    private var currentImageData: Data? {
        guard let id = currentItem?.id else { return nil }
        return loadedDataByID[id]
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
                            loadImageData: loadImageData,
                            onLoaded: { data in
                                loadedDataByID[item.id] = data
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
                    if let exportedURL {
                        ShareLink(item: exportedURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share media")
                    } else if let currentItem {
                        Button {
                            let target = currentItem
                            isExporting = true
                            Task {
                                let url = await exportItem(target)
                                if currentID == target.id { exportedURL = url }
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
                    if currentItem?.isImage == true, currentImageData != nil {
                        Menu {
                            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                                Task { await saveCurrentToPhotos() }
                            }
                            Button("Copy Photo", systemImage: "doc.on.doc") {
                                copyCurrentPhoto()
                            }
                            if let onSaveAsSticker, let data = currentImageData, let item = currentItem {
                                Divider()
                                Button("Save as Sticker", systemImage: "face.smiling") {
                                    onSaveAsSticker(data, item.caption ?? item.title)
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
                exportedURL = nil
                isExporting = false
                isZoomed = false
            }
        }
        .presentationDragIndicator(.visible)
        .onDisappear { toastTask?.cancel() }
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
                    if currentItem.isImage, currentImageData != nil {
                        Button {
                            Task { await saveCurrentToPhotos() }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.body.weight(.medium))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Save to Photos")

                        if let onSaveAsSticker, let data = currentImageData {
                            Button {
                                onSaveAsSticker(data, currentItem.caption ?? currentItem.title)
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
    private func copyCurrentPhoto() {
        guard let data = currentImageData, let image = UIImage(data: data) else { return }  // decode: the full photo, once, on the person's request
        UIPasteboard.general.image = image
        showToast("Copied")
    }

    private func saveCurrentToPhotos() async {
        guard let data = currentImageData else { return }
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showToast("Allow Photos access in Settings")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            showToast("Saved to Photos")
        } catch {
            showToast("Couldn't save photo")
        }
        #endif
    }
    #endif

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
    let loadImageData: @Sendable (PagedMediaItem) async -> Data?
    let onLoaded: @MainActor (Data) -> Void
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void

    @State private var data: Data?
    @State private var isLoading = false
    #if canImport(UIKit)
    /// The photo decoded off the main thread, at most `ImagePipeline.Size.viewer` on the long side.
    @State private var viewerImage: UIImage?
    #endif

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
                    ProgressView().tint(HaloColor.mediaOverlayForeground)
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
        .task(id: item.id) {
            guard item.isImage, data == nil else { return }
            isLoading = true
            let loaded = await loadImageData(item)
            data = loaded
            if let loaded {
                onLoaded(loaded)
                #if canImport(UIKit)
                viewerImage = await ImagePipeline.decode(loaded, maxPixel: ImagePipeline.Size.viewer)
                #endif
            }
            isLoading = false
        }
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
