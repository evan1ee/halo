#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// Inline video poster card rendered in the timeline (MEDIA_ATTACHMENTS FR-2, AC-MED-3, M20-3).
///
/// Preserves the video's portrait or landscape aspect ratio (`VideoDisplayMetrics.aspectRatio`) so list scrolling never
/// jumps when posters load. Tapping streams the video file to disk and opens the full-screen `VideoPlayerSheet`; while
/// downloading, shows progress and a Cancel button. Optional captions render cleanly beneath the poster.
struct VideoPosterView: View {
    let row: TimelineRow
    let video: TimelineRow.Video
    let isOpening: Bool
    let model: TimelineViewModel
    let isOwn: Bool
    let open: () -> Void
    let cancel: () -> Void

    private var durationBadge: String? {
        if let duration = video.duration, duration > 0 {
            return AudioPlaybackMath.formatTime(duration)
        }
        if let size = video.size, size > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return nil
    }

    private var openingDetail: String {
        if let size = video.size, size > 0 {
            return "Loading… · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return "Loading…"
    }

    private var posterAccessibilityLabel: String {
        var parts = ["Video"]
        if let duration = video.duration, duration > 0 {
            parts.append(AudioPlaybackMath.spokenTime(duration))
        }
        if let caption = video.caption {
            parts.append(caption)
        }
        return parts.joined(separator: ", ")
    }

    /// Caps portrait video width so 9:16 clips stay compact and legible in the timeline.
    private var maxPosterWidth: CGFloat {
        video.aspectRatio < 0.85 ? 210 : 270
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            posterSurface

            if let caption = video.caption {
                Text(caption)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HaloSpacing.m)
                    .padding(.vertical, HaloSpacing.s)
                    .frame(maxWidth: maxPosterWidth, alignment: .leading)
                    .accessibilityIdentifier("video-caption")
            }
        }
        .background(
            video.caption != nil ? (isOwn ? HaloColor.bubbleOwn : HaloColor.bubbleOther) : .clear,
            in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
        .opacity(row.status == nil ? 1 : 0.6)
        .accessibilityIdentifier("video-poster-card")
    }

    @ViewBuilder
    private var posterSurface: some View {
        if !model.showsPreview(of: video) {
            Button {
                model.revealPreview(of: video)
            } label: {
                VStack(spacing: HaloSpacing.xs) {
                    Image(systemName: "video")
                        .font(HaloTypography.title)
                    Text("Tap to show video")
                        .font(HaloTypography.meta)
                    if let badge = durationBadge {
                        Text(badge)
                            .font(HaloTypography.caption.monospacedDigit())
                            .foregroundStyle(HaloColor.textSecondary)
                    }
                }
                .foregroundStyle(HaloColor.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HaloColor.bgSecondary)
            }
            .buttonStyle(.plain)
            .aspectRatio(video.aspectRatio, contentMode: .fit)
            .frame(maxWidth: maxPosterWidth)
            .accessibilityIdentifier("show-video")
        } else {
            ZStack {
                if let thumbnail = video.thumbnail {
                    ThumbnailView(image: thumbnail, model: model)
                        .allowsHitTesting(false)
                } else {
                    posterFallback
                }

                // Subtle dark scrim for crisp play-button and badge contrast.
                HaloColor.mediaOverlayBackground.opacity(0.28)
                    .allowsHitTesting(false)

                if isOpening {
                    openingOverlay
                } else {
                    playOverlay
                }
            }
            .aspectRatio(video.aspectRatio, contentMode: .fit)
            .frame(maxWidth: maxPosterWidth)
            .overlay(alignment: .bottomTrailing) {
                if !isOpening, let badge = durationBadge {
                    Text(badge)
                        .font(HaloTypography.captionEmphasis.monospacedDigit())
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .foregroundStyle(HaloColor.mediaOverlayForeground)
                        .padding(.horizontal, HaloSpacing.s)
                        .padding(.vertical, HaloSpacing.xxs)
                        .background(HaloColor.mediaOverlayBackground, in: .capsule)
                        .padding(HaloSpacing.s)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: isOpening ? .contain : .ignore)
            .accessibilityLabel(posterAccessibilityLabel)
            .accessibilityHint(isOpening ? "Video is downloading" : "Opens full-screen video player")
            .accessibilityAddTraits(isOpening ? [] : .isButton)
        }
    }

    private var posterFallback: some View {
        ZStack {
            if let hash = video.blurhash, let decoded = BlurHashDecoder.decode(hash, width: 24, height: 24) {
                RGBAPlaceholderImage(width: decoded.width, height: decoded.height, rgba: decoded.rgba)
            } else {
                HaloColor.mediaBackdrop
            }
        }
    }

    private var playOverlay: some View {
        Button(action: open) {
            ZStack {
                Circle()
                    .fill(HaloColor.mediaOverlayBackground)
                    .overlay(Circle().strokeBorder(HaloColor.mediaOverlayForeground.opacity(0.32), lineWidth: 1))
                    .frame(width: 54, height: 54)
                Image(systemName: "play.fill")
                    .font(HaloTypography.title)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                    .offset(x: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(ScrollFriendlyTapButtonStyle())
        .accessibilityLabel("Play video")
        .accessibilityIdentifier("video-play-button")
    }

    private var openingOverlay: some View {
        VStack(spacing: HaloSpacing.s) {
            ProgressView()
                .tint(HaloColor.mediaOverlayForeground)
                .controlSize(.regular)

            Text(openingDetail)
                .font(HaloTypography.captionEmphasis)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(HaloColor.mediaOverlayForeground)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark")
                    .font(HaloTypography.captionEmphasis)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(HaloColor.mediaOverlayForeground)
                    .padding(.horizontal, HaloSpacing.m)
                    .padding(.vertical, HaloSpacing.xs)
                    .background(HaloColor.mediaOverlayBackground, in: .capsule)
                    .overlay(Capsule().strokeBorder(HaloColor.mediaOverlayForeground.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel loading video")
            .accessibilityIdentifier("cancel-open-video")
        }
        .padding(HaloSpacing.m)
        .background(HaloColor.mediaOverlayBackground, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
        .padding(HaloSpacing.s)
    }
}
#endif
