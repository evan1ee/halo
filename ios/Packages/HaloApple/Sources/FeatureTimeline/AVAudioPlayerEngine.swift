@preconcurrency import AVFoundation
import Foundation
import HaloDomain

/// `AVPlayer`-backed `AudioPlayerEngine` streaming from a local disk file (M19-5, M20-2).
///
/// Supports AAC (`.m4a`), Ogg Opus (`.ogg`, Element voice notes on iOS 26), MP3, WAV, FLAC, and CAF,
/// pitch-preserving variable speed (`1×`, `1.5×`, `2×`), and `AVAudioSession` interruption / route-change handling.
@MainActor
public final class AVAudioPlayerEngine: AudioPlayerEngine {
    public var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var durationTask: Task<Void, Never>?
    private var isVoice = false
    private var sessionActive = false

    public init() {}

    isolated deinit {
        tearDown()
    }

    public func load(url: URL, isVoice: Bool) throws {
        tearDown()
        self.isVoice = isVoice

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = isVoice ? .timeDomain : .spectral

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .failed {
                    self.onEvent?(.failed("Couldn't play audio."))
                }
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated {
                self?.onEvent?(.timeUpdated(seconds))
            }
        }

        durationTask = Task { [weak self] in
            guard let loaded = try? await asset.load(.duration) else { return }  // best-effort: duration falls back to metadata or periodic observer
            guard !Task.isCancelled else { return }
            let seconds = CMTimeGetSeconds(loaded)
            if seconds.isFinite, seconds > 0 {
                self?.onEvent?(.durationKnown(seconds))
            }
        }

        installObservers(for: item)
    }

    public func play(rate: Double) throws {
        guard let player else { return }
        try activateSessionIfNeeded()
        player.playImmediately(atRate: Float(rate))
    }

    public func pause() {
        player?.pause()
    }

    public func setRate(_ rate: Double) {
        guard let player, player.timeControlStatus != .paused else { return }
        player.rate = Float(rate)
    }

    public func seek(to seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func stop() {
        tearDown()
    }

    // MARK: Private

    private func installObservers(for item: AVPlayerItem) {
        let center = NotificationCenter.default

        let endObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEvent?(.didFinish)
            }
        }
        let failObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEvent?(.failed("Couldn't play audio."))
            }
        }
        notificationObservers = [endObserver, failObserver]

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self?.onEvent?(.interruptedBegan)
                case .ended:
                    self?.onEvent?(.interruptedEnded(shouldResume: shouldResume))
                @unknown default:
                    break
                }
            }
        }
        let routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            else { return }
            if reason == .oldDeviceUnavailable {
                MainActor.assumeIsolated {
                    self?.onEvent?(.routeBecameUnavailable)
                }
            }
        }
        notificationObservers.append(contentsOf: [interruptionObserver, routeObserver])
        #endif
    }

    private func activateSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: isVoice ? .spokenAudio : .default, options: [])
        try session.setActive(true)
        sessionActive = true
        #endif
    }

    private func deactivateSessionIfNeeded() {
        #if os(iOS)
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func tearDown() {
        durationTask?.cancel()
        durationTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        deactivateSessionIfNeeded()
    }
}

/// Decodes an audio file off the main actor with `AVAssetReader` to derive waveform bars when MSC1767 metadata is absent.
enum AudioWaveformExtractor {
    /// Extracts up to `barCount` normalised `[0, 1]` peak amplitude bars from `url`; returns `nil` if unreadable.
    @concurrent static func extract(from url: URL, barCount: Int) async -> [Float]? {
        guard barCount > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }  // best-effort: falls back to deterministic bars
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Keep memory tiny even on a long audio file: reduce each buffer into coarse peak buckets (max 256 buckets).
        let targetBuckets = max(barCount * 4, 128)
        var rawPeaks: [Float] = []
        rawPeaks.reserveCapacity(targetBuckets * 2)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer, length >= MemoryLayout<Float>.size else { continue }
            let sampleCount = length / MemoryLayout<Float>.size
            let strideSize = max(1, sampleCount / 8)
            pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floats in
                var index = 0
                while index < sampleCount {
                    let end = min(sampleCount, index + strideSize)
                    var peak: Float = 0
                    for idx in index..<end {
                        let mag = abs(floats[idx])
                        if mag > peak { peak = mag }
                    }
                    rawPeaks.append(peak)
                    index = end
                }
            }
            // Compact periodically so very long recordings stay bounded in memory.
            if rawPeaks.count > targetBuckets * 4 {
                rawPeaks = WaveformResampler.resample(rawPeaks, to: targetBuckets)
            }
        }

        guard reader.status == .completed, !rawPeaks.isEmpty else { return nil }
        let maxPeak = rawPeaks.max() ?? 0
        let normalized = maxPeak > 0.001 ? rawPeaks.map { $0 / maxPeak } : rawPeaks
        return WaveformResampler.resample(normalized, to: barCount)
    }
}
