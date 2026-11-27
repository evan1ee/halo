#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Inline voice and audio message player rendered inside a timeline bubble (MEDIA_ATTACHMENTS FR-3, AC-MED-4, M20-2).
///
/// Reads `player.activeID == row.id` before touching live playback properties (`currentTime`, `phase`, `rate`) so
/// inactive audio rows never re-render while another message plays.
struct AudioBubbleView: View {
    let row: TimelineRow
    let audio: TimelineRow.Audio
    let model: TimelineViewModel
    let isOwn: Bool

    @State private var scrubbingFraction: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var player: AudioPlaybackController { model.audioPlayer }

    /// Only true for the single currently active row; inactive rows avoid observing `currentTime`.
    private var isActive: Bool { player.activeID == row.id }

    private var phase: AudioPlaybackController.Phase {
        isActive ? player.phase : .idle
    }

    private var effectiveDuration: TimeInterval {
        if isActive, player.duration > 0 { return player.duration }
        return max(0, audio.duration ?? 0)
    }

    private var displayedTime: TimeInterval {
        guard isActive else { return effectiveDuration }
        if let scrubbingFraction, effectiveDuration > 0 {
            return AudioPlaybackMath.seekTime(forFraction: scrubbingFraction, duration: effectiveDuration)
        }
        switch phase {
        case .playing, .paused:
            return player.currentTime
        case .idle, .loading, .failed:
            return effectiveDuration
        }
    }

    private var progress: Double {
        if let scrubbingFraction { return min(1, max(0, scrubbingFraction)) }
        guard isActive else { return 0 }
        return AudioPlaybackMath.progress(currentTime: player.currentTime, duration: effectiveDuration)
    }

    private var bars: [Float] {
        if let provided = audio.waveform, !provided.isEmpty {
            return WaveformResampler.resample(provided, to: WaveformResampler.defaultBarCount)
        }
        if let extracted = player.extractedWaveforms[row.id], !extracted.isEmpty {
            return extracted
        }
        return WaveformResampler.fallback(seed: row.id, count: WaveformResampler.defaultBarCount)
    }

    private var canScrub: Bool {
        isActive && (phase == .playing || phase == .paused) && effectiveDuration > 0
    }

    private var playButtonSymbol: String {
        switch phase {
        case .playing: "pause.fill"
        case .failed: "arrow.clockwise"
        case .idle, .paused, .loading: "play.fill"
        }
    }

    private var playButtonLabel: String {
        let kind = audio.isVoice ? "voice message" : "audio"
        switch phase {
        case .playing: return "Pause \(kind)"
        case .loading: return "Cancel loading \(kind)"
        case .failed: return "Retry \(kind)"
        case .idle, .paused: return "Play \(kind)"
        }
    }

    private var sizeText: String? {
        guard let size = audio.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var subtitleText: String {
        if !audio.isVoice {
            let trimmed = audio.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return sizeText ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            HStack(alignment: .center, spacing: HaloSpacing.s) {
                playButton

                VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                    if !audio.isVoice, !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(HaloTypography.captionEmphasis)
                            .foregroundStyle(HaloColor.textPrimary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }

                    waveformBar

                    metadataRow
                }
            }

            if case .failed(let message) = phase {
                Text(message)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("audio-error")
            }
        }
        .padding(.horizontal, HaloSpacing.m)
        .padding(.vertical, HaloSpacing.s)
        .frame(minWidth: 220, maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 270, alignment: .leading)
        .background(
            isOwn ? HaloColor.bubbleOwn : HaloColor.bubbleOther,
            in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous)
        )
        .opacity(row.status == nil ? 1 : 0.6)
        .accessibilityIdentifier("audio-bubble")
    }

    private var playButton: some View {
        Button {
            model.toggleAudioPlayback(for: row)
        } label: {
            ZStack {
                Circle()
                    .fill(HaloColor.accent)
                    .frame(width: 40, height: 40)
                if phase == .loading {
                    ProgressView()
                        .tint(HaloColor.onAccent)
                        .controlSize(.small)
                } else {
                    Image(systemName: playButtonSymbol)
                        .font(HaloTypography.bodyEmphasis)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(HaloColor.onAccent)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playButtonLabel)
        .accessibilityIdentifier("audio-play-button")
    }

    private var waveformBar: some View {
        WaveformBarsShape(bars: bars, progress: progress)
            .frame(height: 28)
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { location in
                            let width = max(1, geometry.size.width)
                            handleWaveformTap(fraction: min(1, max(0, Double(location.x / width))))
                        }
                        #if canImport(UIKit)
                        .gesture(
                            HorizontalScrubGesture(
                                width: geometry.size.width,
                                onChanged: { fraction in
                                    guard canScrub else { return }
                                    scrubbingFraction = fraction
                                },
                                onEnded: { fraction in
                                    guard canScrub else {
                                        scrubbingFraction = nil
                                        return
                                    }
                                    scrubbingFraction = nil
                                    player.seek(itemID: row.id, toFraction: fraction)
                                },
                                onCancelled: {
                                    scrubbingFraction = nil
                                }
                            )
                        )
                        #endif
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(audio.isVoice ? "Voice message position" : "Audio position")
            .accessibilityValue(waveformAccessibilityValue)
            .accessibilityHint(canScrub ? "Swipe up or down to seek" : "Double-tap play to start listening")
            .accessibilityAdjustableAction { direction in
                guard canScrub else { return }
                switch direction {
                case .increment:
                    player.stepSeek(itemID: row.id, forward: true)
                case .decrement:
                    player.stepSeek(itemID: row.id, forward: false)
                @unknown default:
                    break
                }
            }
            .accessibilityIdentifier("audio-waveform")
    }

    private var waveformAccessibilityValue: String {
        let total = effectiveDuration
        if isActive, phase == .playing || phase == .paused, total > 0 {
            return "\(AudioPlaybackMath.spokenTime(displayedTime)) of \(AudioPlaybackMath.spokenTime(total))"
        }
        if total > 0 {
            return AudioPlaybackMath.spokenTime(total)
        }
        return "Ready to play"
    }

    @ViewBuilder
    private var metadataRow: some View {
        let timeLabel = Text(timeSummary)
            .font(HaloTypography.caption.monospacedDigit())
            .foregroundStyle(HaloColor.textSecondary)
            .lineLimit(1)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                timeLabel
                if isActive, phase == .playing || phase == .paused {
                    speedButton
                }
            }
        } else {
            HStack(spacing: HaloSpacing.s) {
                timeLabel
                Spacer(minLength: HaloSpacing.xs)
                if isActive, phase == .playing || phase == .paused {
                    speedButton
                }
            }
        }
    }

    private var timeSummary: String {
        if phase == .loading { return "Loading…" }
        if isActive, phase == .playing || phase == .paused {
            if effectiveDuration > 0 {
                return "\(AudioPlaybackMath.formatTime(displayedTime)) / \(AudioPlaybackMath.formatTime(effectiveDuration))"
            }
            return AudioPlaybackMath.formatTime(displayedTime)
        }
        if effectiveDuration > 0 {
            return AudioPlaybackMath.formatTime(effectiveDuration)
        }
        if audio.isVoice {
            return "Voice message"
        }
        return sizeText ?? "Audio"
    }

    private var speedButton: some View {
        let rate = player.rate
        return Button {
            player.cycleRate()
        } label: {
            Text(rate.label)
                .font(HaloTypography.captionEmphasis.monospacedDigit())
                .foregroundStyle(HaloColor.accent)
                .padding(.horizontal, HaloSpacing.s)
                .padding(.vertical, HaloSpacing.xxs)
                .background(HaloColor.accent.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(rate.spokenLabel)
        .accessibilityHint("Changes playback speed")
        .accessibilityIdentifier("audio-speed-button")
    }

    private func handleWaveformTap(fraction: Double) {
        if canScrub {
            player.seek(itemID: row.id, toFraction: fraction)
        } else if case .idle = phase {
            model.toggleAudioPlayback(for: row)
        } else if case .failed = phase {
            model.toggleAudioPlayback(for: row)
        }
    }
}

/// Renders the 32 vertical capsule bars of the audio waveform with crisp played/unplayed tinting.
private struct WaveformBarsShape: View {
    let bars: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, bars.count)
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(0, count - 1))
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(count))
            let maxHeight = max(6, geometry.size.height)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, amplitude in
                    let barPosition = Double(index) / Double(count)
                    let played = progress > 0 && barPosition < progress
                    let height = max(4, CGFloat(amplitude) * maxHeight)
                    Capsule(style: .continuous)
                        .fill(played ? HaloColor.accent : HaloColor.textSecondary.opacity(0.38))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

#if canImport(UIKit)
/// Horizontal-only pan scrubber that never steals vertical scrolling from the enclosing timeline `List`.
private struct HorizontalScrubGesture: UIGestureRecognizerRepresentable {
    let width: CGFloat
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .local)
        let fraction = width > 0 ? min(1, max(0, Double(point.x / width))) : 0
        switch recognizer.state {
        case .began, .changed:
            onChanged(fraction)
        case .ended:
            onEnded(fraction)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            // Only engage horizontal drags so vertical swipes pass straight through to the timeline List.
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#endif
#endif
