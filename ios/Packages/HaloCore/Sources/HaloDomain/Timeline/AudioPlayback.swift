import Foundation

/// Playback speeds offered by the inline audio and voice player (MEDIA_ATTACHMENTS FR-3, M20-2).
public enum AudioPlaybackRate: Double, CaseIterable, Sendable, Equatable {
    case one = 1.0
    case onePointFive = 1.5
    case two = 2.0

    /// Compact pill label (`"1×"`, `"1.5×"`, `"2×"`).
    public var label: String {
        switch self {
        case .one: "1×"
        case .onePointFive: "1.5×"
        case .two: "2×"
        }
    }

    /// Spoken VoiceOver description.
    public var spokenLabel: String {
        switch self {
        case .one: "1 times speed"
        case .onePointFive: "1.5 times speed"
        case .two: "2 times speed"
        }
    }

    /// Cycles `1× → 1.5× → 2× → 1×`.
    public var next: AudioPlaybackRate {
        switch self {
        case .one: .onePointFive
        case .onePointFive: .two
        case .two: .one
        }
    }
}

/// Pure helpers for MSC1767 audio waveforms and recorder metering (MEDIA_ATTACHMENTS FR-3, M20-2).
public enum WaveformResampler {
    /// MSC1767 encodes waveform amplitudes as integers in `0...1024`.
    public static let msc1767Scale: Float = 1024
    /// Default visual bar count rendered in a timeline audio bubble.
    public static let defaultBarCount = 32
    /// Default sample count sent in outgoing MSC1767 voice messages (spec recommends 30–100).
    public static let outgoingSampleCount = 64

    /// Converts MSC1767 integer amplitudes (`0...1024`) to normalised `[0, 1]` floats.
    /// Returns `nil` when `raw` is empty.
    public static func fromMSC1767(_ raw: [UInt16]) -> [Float]? {
        guard !raw.isEmpty else { return nil }
        return raw.map { min(1, max(0, Float($0) / msc1767Scale)) }
    }

    /// Resamples arbitrary amplitude samples to `count` normalised `[0, 1]` bars.
    /// Downsampling keeps bucket peaks so spoken syllables stay legible; upsampling linearly interpolates.
    public static func resample(_ samples: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let clamped = samples.map { value -> Float in
            guard value.isFinite else { return 0 }
            return min(1, max(0, value))
        }
        guard !clamped.isEmpty else { return Array(repeating: 0.2, count: count) }
        if clamped.count == 1 { return Array(repeating: clamped[0], count: count) }
        if clamped.count == count { return clamped }

        if clamped.count > count {
            var output: [Float] = []
            output.reserveCapacity(count)
            for bar in 0..<count {
                let start = (bar * clamped.count) / count
                let end = max(start + 1, ((bar + 1) * clamped.count) / count)
                var peak: Float = 0
                for idx in start..<min(end, clamped.count) where clamped[idx] > peak {
                    peak = clamped[idx]
                }
                output.append(peak)
            }
            return output
        }

        var output: [Float] = []
        output.reserveCapacity(count)
        let lastIndex = Float(clamped.count - 1)
        let denominator = Float(max(1, count - 1))
        for bar in 0..<count {
            let position = (Float(bar) / denominator) * lastIndex
            let lower = Int(position.rounded(.down))
            let upper = min(clamped.count - 1, lower + 1)
            let fraction = position - Float(lower)
            let value = clamped[lower] * (1 - fraction) + clamped[upper] * fraction
            output.append(min(1, max(0, value)))
        }
        return output
    }

    /// Deterministic fallback bars for an audio message that carried no MSC1767 waveform metadata.
    /// Uses FNV-1a hashing so bars stay identical across launches and scroll recycling.
    public static func fallback(seed: String, count: Int = defaultBarCount) -> [Float] {
        guard count > 0 else { return [] }
        var state: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            state ^= UInt64(byte)
            state &*= 1_099_511_628_211
        }
        var bars: [Float] = []
        bars.reserveCapacity(count)
        for index in 0..<count {
            state ^= UInt64(index) &+ 0x9E37_79B9_7F4A_7C15
            state &*= 1_099_511_628_211
            // Gentle envelope tapering slightly at the ends so fallback bars look calm and uniform.
            let phase = Float(index) / Float(max(1, count - 1))
            let envelope = 0.65 + 0.35 * sin(phase * .pi)
            let unit = Float(state % 1000) / 1000
            bars.append(min(0.85, max(0.18, (0.22 + unit * 0.52) * envelope)))
        }
        return bars
    }

    /// Maps an `AVAudioRecorder` average power reading in decibels (`[-55, 0]`) to `[0, 1]`.
    public static func normalizeMetering(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        let floorDB: Float = -55
        if decibels <= floorDB { return 0 }
        if decibels >= 0 { return 1 }
        return (decibels - floorDB) / -floorDB
    }
}

/// Pure time/scrubbing/accessibility math for inline audio playback (M20-2).
public enum AudioPlaybackMath {
    /// Default scrub increment for VoiceOver adjustable actions (seconds).
    public static let voiceOverStepSeconds: TimeInterval = 5

    /// Normalised `[0, 1]` playback progress.
    public static func progress(currentTime: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    /// Target time in seconds for a normalised `[0, 1]` scrub position.
    public static func seekTime(forFraction fraction: Double, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0, fraction.isFinite else { return 0 }
        return min(duration, max(0, fraction * duration))
    }

    /// Target time after a VoiceOver adjustable increment or decrement.
    /// Uses `step` (default 5 s), shrinking to 1 s for very short clips (< 5 s) so every clip is scrubbable.
    public static func steppedTime(
        current: TimeInterval, duration: TimeInterval, forward: Bool, step: TimeInterval = voiceOverStepSeconds
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        let safeCurrent = current.isFinite ? min(duration, max(0, current)) : 0
        let effectiveStep = duration < step ? max(1, duration / 5) : step
        let delta = forward ? effectiveStep : -effectiveStep
        return min(duration, max(0, safeCurrent + delta))
    }

    /// Compact clock string (`"0:07"`, `"1:23"`, `"1:02:03"`).
    public static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        let paddedSecs = secs < 10 ? "0\(secs)" : "\(secs)"
        if hours > 0 {
            let paddedMins = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(paddedMins):\(paddedSecs)"
        }
        return "\(minutes):\(paddedSecs)"
    }

    /// Natural spoken duration for VoiceOver (`"0 seconds"`, `"1 minute, 5 seconds"`).
    public static func spokenTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 seconds" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if secs > 0 || parts.isEmpty { parts.append(secs == 1 ? "1 second" : "\(secs) seconds") }
        return parts.joined(separator: ", ")
    }
}
