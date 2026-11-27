import Foundation
import HaloDomain
import Testing

@Suite("Audio playback domain helpers")
struct AudioPlaybackTests {
    @Test("Playback rate cycles 1x -> 1.5x -> 2x -> 1x")
    func rateCycling() {
        #expect(AudioPlaybackRate.one.next == .onePointFive)
        #expect(AudioPlaybackRate.onePointFive.next == .two)
        #expect(AudioPlaybackRate.two.next == .one)
        #expect(AudioPlaybackRate.one.label == "1×")
        #expect(AudioPlaybackRate.onePointFive.label == "1.5×")
        #expect(AudioPlaybackRate.two.label == "2×")
    }

    @Test("MSC1767 waveform maps 0...1024 to 0...1 and rejects empty")
    func msc1767Mapping() {
        #expect(WaveformResampler.fromMSC1767([]) == nil)
        let mapped = WaveformResampler.fromMSC1767([0, 512, 1024, 2048])
        #expect(mapped == [0, 0.5, 1, 1])
    }

    @Test("Waveform resampling downsamples by peak, upsamples smoothly, and clamps")
    func resampling() {
        let down = WaveformResampler.resample([0.1, 0.9, 0.2, 0.4], to: 2)
        #expect(down == [0.9, 0.4])

        let up = WaveformResampler.resample([0.0, 1.0], to: 5)
        #expect(up == [0.0, 0.25, 0.5, 0.75, 1.0])

        let clamped = WaveformResampler.resample([-0.5, .nan, 2.0], to: 3)
        #expect(clamped == [0.0, 0.0, 1.0])

        #expect(WaveformResampler.resample([], to: 4).count == 4)
        #expect(WaveformResampler.resample([0.5], to: 0).isEmpty)
    }

    @Test("Fallback waveform is deterministic and bounded")
    func fallbackWaveform() {
        let a = WaveformResampler.fallback(seed: "event-1", count: 32)
        let b = WaveformResampler.fallback(seed: "event-1", count: 32)
        let c = WaveformResampler.fallback(seed: "event-2", count: 32)
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 32)
        #expect(a.allSatisfy { $0 >= 0.18 && $0 <= 0.85 })
    }

    @Test("Recorder metering normalises decibels to [0, 1]")
    func meteringNormalisation() {
        #expect(WaveformResampler.normalizeMetering(decibels: -80) == 0)
        #expect(WaveformResampler.normalizeMetering(decibels: -55) == 0)
        #expect(WaveformResampler.normalizeMetering(decibels: 0) == 1)
        #expect(WaveformResampler.normalizeMetering(decibels: 3) == 1)
        #expect(WaveformResampler.normalizeMetering(decibels: -.infinity) == 0)
        let mid = WaveformResampler.normalizeMetering(decibels: -27.5)
        #expect(abs(mid - 0.5) < 0.01)
    }

    @Test("Progress, scrub seek, VoiceOver stepping, and time formatting")
    func playbackMath() {
        #expect(AudioPlaybackMath.progress(currentTime: 5, duration: 20) == 0.25)
        #expect(AudioPlaybackMath.progress(currentTime: 30, duration: 20) == 1)
        #expect(AudioPlaybackMath.progress(currentTime: 5, duration: 0) == 0)

        #expect(AudioPlaybackMath.seekTime(forFraction: 0.5, duration: 10) == 5)
        #expect(AudioPlaybackMath.seekTime(forFraction: -0.2, duration: 10) == 0)
        #expect(AudioPlaybackMath.seekTime(forFraction: 1.5, duration: 10) == 10)

        #expect(AudioPlaybackMath.steppedTime(current: 4, duration: 30, forward: true) == 9)
        #expect(AudioPlaybackMath.steppedTime(current: 28, duration: 30, forward: true) == 30)
        #expect(AudioPlaybackMath.steppedTime(current: 2, duration: 30, forward: false) == 0)
        // Short clip (< 5 s) steps by 1 s instead of jumping straight to the end.
        #expect(AudioPlaybackMath.steppedTime(current: 0, duration: 3, forward: true) == 1)

        #expect(AudioPlaybackMath.formatTime(0) == "0:00")
        #expect(AudioPlaybackMath.formatTime(7.8) == "0:07")
        #expect(AudioPlaybackMath.formatTime(83) == "1:23")
        #expect(AudioPlaybackMath.formatTime(3723) == "1:02:03")

        #expect(AudioPlaybackMath.spokenTime(0) == "0 seconds")
        #expect(AudioPlaybackMath.spokenTime(1) == "1 second")
        #expect(AudioPlaybackMath.spokenTime(65) == "1 minute, 5 seconds")
    }

    @Test("OutgoingFile preserves voice metadata and validates")
    func outgoingVoiceFile() throws {
        let voice = OutgoingFile(
            data: Data([1, 2, 3]), filename: "Voice message.m4a", mimeType: "audio/mp4",
            duration: 3.5, waveform: [0.2, 0.8], isVoiceMessage: true
        )
        try voice.validate()
        #expect(voice.kind == .audio)
        #expect(voice.isVoiceMessage)
        #expect(voice.duration == 3.5)
        #expect(voice.waveform == [0.2, 0.8])
    }
}
