#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
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
public struct PagedPhotoViewer: View {
    private let items: [PagedMediaItem]
    @State private var currentID: String
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @Environment(\.dismiss) private var dismiss

    private let loadImageData: @Sendable (PagedMediaItem) async -> Data?
    private let exportItem: @Sendable (PagedMediaItem) async -> URL?
    private let onJumpToMessage: ((PagedMediaItem) -> Void)?

    public init(
        items: [PagedMediaItem],
        initialID: String,
        loadImageData: @escaping @Sendable (PagedMediaItem) async -> Data?,
        exportItem: @escaping @Sendable (PagedMediaItem) async -> URL?,
        onJumpToMessage: ((PagedMediaItem) -> Void)? = nil
    ) {
        self.items = items
        _currentID = State(initialValue: initialID)
        self.loadImageData = loadImageData
        self.exportItem = exportItem
        self.onJumpToMessage = onJumpToMessage
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    private var currentItem: PagedMediaItem? {
        guard !items.isEmpty else { return nil }
        return items[currentIndex]
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                HaloColor.mediaBackdrop.ignoresSafeArea()
                TabView(selection: $currentID) {
                    ForEach(items) { item in
                        PagedPhotoPage(item: item, loadImageData: loadImageData)
                            .tag(item.id)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif

                if let caption = currentItem?.caption, !caption.isEmpty {
                    Text(caption)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, HaloSpacing.l)
                        .padding(.vertical, HaloSpacing.m)
                        .frame(maxWidth: .infinity)
                        .background(HaloColor.mediaOverlayBackground)
                }
            }
            .navigationTitle(
                items.count > 1
                    ? "\(currentIndex + 1) of \(items.count)"
                    : (currentItem?.title ?? "Media")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
                }
            }
            .onChange(of: currentID) {
                exportedURL = nil
                isExporting = false
            }
        }
    }
}

private struct PagedPhotoPage: View {
    let item: PagedMediaItem
    let loadImageData: @Sendable (PagedMediaItem) async -> Data?
    @State private var data: Data?
    @State private var isLoading = false

    var body: some View {
        Group {
            #if canImport(UIKit)
            if item.isImage {
                if let data, let image = UIImage(data: data) {
                    ZoomableImageView(image: image)
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
            guard item.isImage else { return }
            data = nil
            isLoading = true
            data = await loadImageData(item)
            isLoading = false
        }
    }

    private var fallbackView: some View {
        VStack(spacing: HaloSpacing.m) {
            Image(systemName: item.fallbackSymbol)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(HaloColor.textSecondary)
            Text(item.title)
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}
#endif
