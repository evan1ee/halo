#if canImport(SwiftUI)
@preconcurrency import AVFoundation
import AVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Photos)
import Photos
#endif

/// Full-screen native video player streaming directly from a disk file URL (MEDIA_ATTACHMENTS FR-2, M19-5, M20-3).
///
/// Uses `AVPlayerViewController` on iOS for native playback controls, portrait and landscape rotation,
/// AirPlay, Picture-in-Picture, and memory-safe disk streaming (AC-MED-3). Offers Save to Photos and Share
/// directly from the on-disk file and deletes its temporary folder on dismissal.
public struct VideoPlayerSheet: View {
    public let fileURL: URL
    public let title: String
    public let caption: String?
    public let onDismiss: @MainActor () -> Void

    @State private var player: AVPlayer?
    @State private var playbackFailed = false
    @State private var statusObservation: NSKeyValueObservation?
    @State private var failObserver: NSObjectProtocol?
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        fileURL: URL,
        title: String,
        caption: String? = nil,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.fileURL = fileURL
        self.title = title
        self.caption = caption
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                HaloColor.mediaBackdrop.ignoresSafeArea()

                if playbackFailed {
                    ContentUnavailableView {
                        Label("Can't play video", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HaloColor.mediaOverlayForeground)
                    } description: {
                        Text("This video format couldn't be played here. You can still share or save the file.")
                            .foregroundStyle(HaloColor.mediaOverlayForeground.opacity(0.8))
                    } actions: {
                        ShareLink(item: fileURL) {
                            Label("Share video", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(HaloSpacing.l)
                } else if let player {
                    #if canImport(UIKit)
                    NativeAVPlayerView(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("video-player-surface")
                    #else
                    VideoPlayer(player: player)
                    #endif
                } else {
                    ProgressView()
                        .tint(HaloColor.mediaOverlayForeground)
                }

                if let caption, !caption.isEmpty, !playbackFailed {
                    Text(caption)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .padding(.horizontal, HaloSpacing.m)
                        .padding(.vertical, HaloSpacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HaloColor.mediaOverlayBackground)
                        .padding(.bottom, 76)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("video-player-caption")
                }

                if let toastMessage {
                    Text(toastMessage)
                        .font(HaloTypography.captionEmphasis)
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .padding(.horizontal, HaloSpacing.m)
                        .padding(.vertical, HaloSpacing.s)
                        .haloOverlayPillBackground()
                        .environment(\.colorScheme, .dark)
                        .padding(.bottom, 96)
                        .transition(HaloMotion.slide(from: .bottom, reduceMotion: reduceMotion))
                        .zIndex(2)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("video-viewer-done")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share video")
                    .accessibilityIdentifier("video-viewer-share")

                    #if canImport(UIKit)
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Save to Photos")
                    .accessibilityIdentifier("video-viewer-save")
                    #endif
                }
            }
        }
        .onAppear { startPlayback() }
        .onDisappear {
            tearDownPlayback()
            onDismiss()
        }
    }

    private func startPlayback() {
        guard player == nil else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        #endif
        let item = AVPlayerItem(url: fileURL)
        let avPlayer = AVPlayer(playerItem: item)
        statusObservation = item.observe(\.status, options: [.new]) { observed, _ in
            let status = observed.status
            Task { @MainActor in
                if status == .failed {
                    playbackFailed = true
                }
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                playbackFailed = true
            }
        }
        player = avPlayer
        avPlayer.play()
    }

    private func tearDownPlayback() {
        toastTask?.cancel()
        toastTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if canImport(UIKit)
    private func saveToPhotos() async {
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showToast("Allow Photos access in Settings")
            return
        }
        let sourceURL = fileURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: sourceURL, options: nil)
            }
            showToast("Saved to Photos")
        } catch {
            showToast("Couldn't save video")
        }
        #endif
    }
    #endif

    private func showToast(_ message: String) {
        toastTask?.cancel()
        HaloMotion.animate(HaloMotion.gentle(reduceMotion: reduceMotion)) {
            toastMessage = message
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            HaloMotion.animate(HaloMotion.gentle(reduceMotion: reduceMotion)) {
                toastMessage = nil
            }
        }
    }
}

#if canImport(UIKit)
private struct NativeAVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
#endif
#endif
