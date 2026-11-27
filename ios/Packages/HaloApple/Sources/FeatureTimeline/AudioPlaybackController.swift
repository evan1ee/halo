import Foundation
import HaloDomain
import HaloFoundation
import Observation

/// Events emitted by an `AudioPlayerEngine` back to `AudioPlaybackController`.
public enum AudioEngineEvent: Sendable, Equatable {
    case durationKnown(TimeInterval)
    case timeUpdated(TimeInterval)
    case didFinish
    case failed(String)
    case interruptedBegan
    case interruptedEnded(shouldResume: Bool)
    case routeBecameUnavailable
}

/// Abstracts the underlying audio player and system audio-session notifications so `AudioPlaybackController`
/// can be deterministically unit-tested without real hardware or sleeps (AGENTS.md §12, M20-2).
@MainActor
public protocol AudioPlayerEngine: AnyObject {
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)? { get set }
    func load(url: URL, isVoice: Bool) throws
    func play(rate: Double) throws
    func pause()
    func setRate(_ rate: Double)
    func seek(to seconds: TimeInterval)
    func stop()
}

/// Owns inline playback of voice messages and audio files for one open timeline (MEDIA_ATTACHMENTS FR-3, AC-MED-4, M20-2).
///
/// Lives on `TimelineViewModel` rather than inside a list row so playback survives SwiftUI row recycling while the user
/// scrolls through the conversation. Only one audio message plays at a time; starting another stops the first and cleans up
/// its temporary file. Handles system interruptions (calls, alarms) and route changes (headphones unplugged).
@MainActor @Observable
public final class AudioPlaybackController {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    public private(set) var activeID: String?
    public private(set) var phase: Phase = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var rate: AudioPlaybackRate = .one
    /// Waveforms extracted from downloaded audio files that carried no MSC1767 waveform metadata.
    public private(set) var extractedWaveforms: [String: [Float]] = [:]

    @ObservationIgnored private let engine: any AudioPlayerEngine
    @ObservationIgnored private let extractWaveform: @Sendable (URL, Int) async -> [Float]?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var activeTempDirectory: URL?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var loadGeneration = 0

    public init(
        engine: any AudioPlayerEngine = AVAudioPlayerEngine(),
        extractWaveform: (@Sendable (URL, Int) async -> [Float]?)? = nil
    ) {
        self.engine = engine
        self.extractWaveform = extractWaveform ?? { url, count in
            await AudioWaveformExtractor.extract(from: url, barCount: count)
        }
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    isolated deinit {
        loadTask?.cancel()
        waveformTask?.cancel()
        engine.stop()
        if let dir = activeTempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Starts, pauses, resumes, or cancels playback for `itemID`.
    public func togglePlay(
        itemID: String,
        announcedDuration: TimeInterval?,
        isVoice: Bool,
        hasWaveform: Bool,
        download: @escaping @MainActor () async throws -> URL
    ) {
        if activeID == itemID {
            switch phase {
            case .playing:
                pause()
                return
            case .paused:
                resume()
                return
            case .loading:
                stop()
                return
            case .idle, .failed:
                break
            }
        }

        startLoading(
            itemID: itemID,
            announcedDuration: announcedDuration,
            isVoice: isVoice,
            hasWaveform: hasWaveform,
            download: download
        )
    }

    /// Pauses the active track, keeping its current position so the user can resume or scrub.
    public func pause() {
        guard phase == .playing else { return }
        wasPlayingBeforeInterruption = false
        engine.pause()
        phase = .paused
    }

    /// Resumes a paused track at the current playback speed.
    public func resume() {
        guard phase == .paused else { return }
        wasPlayingBeforeInterruption = false
        do {
            try engine.play(rate: rate.rawValue)
            phase = .playing
        } catch {
            phase = .failed("Couldn't play audio.")
        }
    }

    /// Cycles playback speed `1× → 1.5× → 2× → 1×`, updating the live player immediately when playing.
    public func cycleRate() {
        rate = rate.next
        if phase == .playing {
            engine.setRate(rate.rawValue)
        }
    }

    /// Seeks the active track to a normalised `[0, 1]` fraction along the waveform.
    public func seek(itemID: String, toFraction fraction: Double) {
        guard activeID == itemID, phase == .playing || phase == .paused, duration > 0 else { return }
        let target = AudioPlaybackMath.seekTime(forFraction: fraction, duration: duration)
        currentTime = target
        engine.seek(to: target)
    }

    /// Steps the active track forward or backward (for VoiceOver `.accessibilityAdjustableAction`).
    public func stepSeek(itemID: String, forward: Bool) {
        guard activeID == itemID, phase == .playing || phase == .paused, duration > 0 else { return }
        let target = AudioPlaybackMath.steppedTime(current: currentTime, duration: duration, forward: forward)
        currentTime = target
        engine.seek(to: target)
    }

    /// Stops playback, cancels any in-flight download, and deletes the temporary audio file.
    public func stop() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        engine.stop()
        cleanUpTempDirectory()
        wasPlayingBeforeInterruption = false
        activeID = nil
        phase = .idle
        currentTime = 0
        duration = 0
    }

    /// Normalised `[0, 1]` progress for `itemID` (`0` for inactive rows).
    public func progress(for itemID: String) -> Double {
        guard activeID == itemID else { return 0 }
        return AudioPlaybackMath.progress(currentTime: currentTime, duration: duration)
    }

    // MARK: Private

    private func startLoading(
        itemID: String,
        announcedDuration: TimeInterval?,
        isVoice: Bool,
        hasWaveform: Bool,
        download: @escaping @MainActor () async throws -> URL
    ) {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        waveformTask?.cancel()
        waveformTask = nil
        engine.stop()
        cleanUpTempDirectory()
        wasPlayingBeforeInterruption = false

        activeID = itemID
        phase = .loading
        currentTime = 0
        duration = max(0, announcedDuration ?? 0)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await download()
                guard !Task.isCancelled, self.loadGeneration == generation, self.activeID == itemID else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                self.activeTempDirectory = url.deletingLastPathComponent()
                do {
                    try self.engine.load(url: url, isVoice: isVoice)
                    try self.engine.play(rate: self.rate.rawValue)
                    self.phase = .playing
                    if !hasWaveform, self.extractedWaveforms[itemID] == nil {
                        self.startWaveformExtraction(itemID: itemID, url: url, generation: generation)
                    }
                } catch {
                    self.engine.stop()
                    self.cleanUpTempDirectory()
                    self.phase = .failed("Couldn't play audio.")
                }
            } catch is CancellationError {
                return
            } catch HaloError.cancelled {
                return
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation, self.activeID == itemID else { return }
                self.phase = .failed(Self.downloadErrorMessage(for: error))
            }
        }
    }

    private func startWaveformExtraction(itemID: String, url: URL, generation: Int) {
        let extract = extractWaveform
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in
            let bars = await extract(url, WaveformResampler.defaultBarCount)
            guard !Task.isCancelled, let self, self.loadGeneration == generation, let bars, !bars.isEmpty else { return }
            self.extractedWaveforms[itemID] = bars
        }
    }

    private func handle(_ event: AudioEngineEvent) {
        guard activeID != nil else { return }
        switch event {
        case .durationKnown(let seconds):
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
        case .timeUpdated(let seconds):
            guard phase == .playing, seconds.isFinite else { return }
            currentTime = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        case .didFinish:
            stop()
        case .failed(let message):
            wasPlayingBeforeInterruption = false
            engine.stop()
            cleanUpTempDirectory()
            phase = .failed(message)
        case .interruptedBegan:
            if phase == .playing {
                wasPlayingBeforeInterruption = true
                engine.pause()
                phase = .paused
            }
        case .interruptedEnded(let shouldResume):
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            if shouldResume, phase == .paused {
                resume()
            }
        case .routeBecameUnavailable:
            if phase == .playing {
                wasPlayingBeforeInterruption = false
                engine.pause()
                phase = .paused
            }
        }
    }

    private func cleanUpTempDirectory() {
        if let dir = activeTempDirectory {
            try? FileManager.default.removeItem(at: dir)
            activeTempDirectory = nil
        }
    }

    private static func downloadErrorMessage(for error: any Error) -> String {
        if let haloError = error as? HaloError {
            switch haloError {
            case .network(retryable: true):
                return "Can't reach the server."
            case .invalidInput:
                return "This audio file is too large to play here."
            default:
                break
            }
        }
        return "Couldn't load audio."
    }
}
