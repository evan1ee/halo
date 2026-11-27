import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import FeatureTimeline

@MainActor
private final class FakeAudioPlayerEngine: AudioPlayerEngine {
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?
    var loaded: [(url: URL, isVoice: Bool)] = []
    var playedRates: [Double] = []
    var setRates: [Double] = []
    var seekedTimes: [TimeInterval] = []
    var pausedCount = 0
    var stoppedCount = 0
    var loadError: (any Error)?
    var playError: (any Error)?

    func load(url: URL, isVoice: Bool) throws {
        if let loadError { throw loadError }
        loaded.append((url, isVoice))
    }

    func play(rate: Double) throws {
        if let playError { throw playError }
        playedRates.append(rate)
    }

    func pause() { pausedCount += 1 }
    func setRate(_ rate: Double) { setRates.append(rate) }
    func seek(to seconds: TimeInterval) { seekedTimes.append(seconds) }
    func stop() { stoppedCount += 1 }

    func emit(_ event: AudioEngineEvent) {
        onEvent?(event)
    }
}

@Suite("Inline audio playback (M20-2)")
@MainActor
struct AudioPlaybackControllerTests {
    private func makeTempAudioFile(name: String = "clip.m4a") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-audio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("audio-bytes".utf8).write(to: url)
        return url
    }

    /// Generates a real 16-bit mono PCM WAV file (440 Hz sine wave) so `AVPlayer` and `AVAssetReader` can decode it.
    private func makeRealWAVFile(durationSeconds: Double = 0.5) throws -> URL {
        let sampleRate: Int = 16_000
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        let dataSize = sampleCount * 2
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize))
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let sample = Int16(sin(2 * .pi * 440 * t) * 16_000)
            appendLE(sample)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-wav-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try data.write(to: url)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("play, pause, resume, rate cycling (1x/1.5x/2x), scrub, and finish clean up temp files")
    func playPauseRateScrubAndFinish() async throws {
        let engine = FakeAudioPlayerEngine()
        let controller = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })
        let fileURL = try makeTempAudioFile()
        let dir = fileURL.deletingLastPathComponent()

        controller.togglePlay(itemID: "row-1", announcedDuration: 20, isVoice: true, hasWaveform: true) { fileURL }
        await waitUntil { controller.phase == .playing }

        #expect(controller.activeID == "row-1")
        #expect(controller.phase == .playing)
        #expect(controller.duration == 20)
        #expect(engine.loaded.count == 1 && engine.loaded[0].isVoice)
        #expect(engine.playedRates == [1.0])

        // Periodic time updates advance progress.
        engine.emit(.timeUpdated(5))
        #expect(controller.currentTime == 5)
        #expect(controller.progress(for: "row-1") == 0.25)
        #expect(controller.progress(for: "other-row") == 0)

        // Speed cycling updates the playing engine immediately.
        controller.cycleRate()
        #expect(controller.rate == .onePointFive)
        controller.cycleRate()
        #expect(controller.rate == .two)
        controller.cycleRate()
        #expect(controller.rate == .one)
        #expect(engine.setRates == [1.5, 2.0, 1.0])

        // Scrubbing seeks and updates currentTime; inactive rows are ignored.
        controller.seek(itemID: "other-row", toFraction: 0.8)
        #expect(engine.seekedTimes.isEmpty)
        controller.seek(itemID: "row-1", toFraction: 0.5)
        #expect(controller.currentTime == 10)
        #expect(engine.seekedTimes == [10])

        // VoiceOver adjustable increment/decrement steps by 5 s.
        controller.stepSeek(itemID: "row-1", forward: true)
        #expect(controller.currentTime == 15)
        controller.stepSeek(itemID: "row-1", forward: false)
        #expect(controller.currentTime == 10)

        // Pause & resume preserve position and speed.
        controller.cycleRate() // 1.5x
        controller.togglePlay(itemID: "row-1", announcedDuration: 20, isVoice: true, hasWaveform: true) { fileURL }
        #expect(controller.phase == .paused)
        #expect(engine.pausedCount == 1)

        controller.togglePlay(itemID: "row-1", announcedDuration: 20, isVoice: true, hasWaveform: true) { fileURL }
        #expect(controller.phase == .playing)
        #expect(engine.playedRates.last == 1.5)

        // Finishing resets state and deletes the temporary folder.
        engine.emit(.didFinish)
        #expect(controller.phase == .idle)
        #expect(controller.activeID == nil)
        #expect(controller.currentTime == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("interruptions (calls) pause and resume per system option; headphones unplugged pauses (AC-MED-4)")
    func interruptionsAndRouteChange() async throws {
        let engine = FakeAudioPlayerEngine()
        let controller = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })
        let fileURL = try makeTempAudioFile()
        defer { controller.stop() }

        controller.togglePlay(itemID: "row-1", announcedDuration: 15, isVoice: true, hasWaveform: true) { fileURL }
        await waitUntil { controller.phase == .playing }

        // Incoming call begins → pauses.
        engine.emit(.interruptedBegan)
        #expect(controller.phase == .paused)

        // Call ends with shouldResume == true → resumes automatically.
        engine.emit(.interruptedEnded(shouldResume: true))
        #expect(controller.phase == .playing)

        // Interruption ending with shouldResume == false stays paused.
        engine.emit(.interruptedBegan)
        #expect(controller.phase == .paused)
        engine.emit(.interruptedEnded(shouldResume: false))
        #expect(controller.phase == .paused)

        // Manual pause before an interruption must not auto-resume.
        engine.emit(.interruptedBegan)
        engine.emit(.interruptedEnded(shouldResume: true))
        #expect(controller.phase == .paused)

        // Resume, then headphones unplug (route unavailable) → pauses.
        controller.resume()
        #expect(controller.phase == .playing)
        engine.emit(.routeBecameUnavailable)
        #expect(controller.phase == .paused)
    }

    @Test("starting a second audio bubble stops the first and cleans up its temporary file")
    func switchingTracksCleansUpFirst() async throws {
        let engine = FakeAudioPlayerEngine()
        let controller = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })
        let first = try makeTempAudioFile(name: "first.m4a")
        let second = try makeTempAudioFile(name: "second.m4a")
        defer { controller.stop() }

        controller.togglePlay(itemID: "a", announcedDuration: 10, isVoice: true, hasWaveform: true) { first }
        await waitUntil { controller.phase == .playing }
        #expect(FileManager.default.fileExists(atPath: first.path))

        controller.togglePlay(itemID: "b", announcedDuration: 12, isVoice: false, hasWaveform: true) { second }
        await waitUntil { controller.activeID == "b" && controller.phase == .playing }
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("offline download error shows honest failure and retry recovers; cancelling while loading cleans up")
    func errorsAndCancelWhileLoading() async throws {
        let engine = FakeAudioPlayerEngine()
        let controller = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })

        controller.togglePlay(itemID: "row-err", announcedDuration: 8, isVoice: true, hasWaveform: true) {
            throw HaloError.network(retryable: true)
        }
        await waitUntil {
            if case .failed = controller.phase { return true }
            return false
        }
        #expect(controller.phase == .failed("Can't reach the server."))

        // Retrying the failed row loads and plays.
        let file = try makeTempAudioFile()
        controller.togglePlay(itemID: "row-err", announcedDuration: 8, isVoice: true, hasWaveform: true) { file }
        await waitUntil { controller.phase == .playing }
        #expect(controller.phase == .playing)

        // Engine playback failure transitions to failed and deletes temp file.
        engine.emit(.failed("Couldn't play audio."))
        #expect(controller.phase == .failed("Couldn't play audio."))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))

        // Cancelling an in-flight download leaves idle without error.
        let gate = AsyncStream<Void>.makeStream()
        controller.togglePlay(itemID: "row-cancel", announcedDuration: 5, isVoice: true, hasWaveform: true) {
            for await _ in gate.stream {}
            throw CancellationError()
        }
        #expect(controller.phase == .loading)
        controller.togglePlay(itemID: "row-cancel", announcedDuration: 5, isVoice: true, hasWaveform: true) {
            throw CancellationError()
        }
        gate.continuation.finish()
        #expect(controller.phase == .idle)
        #expect(controller.activeID == nil)
    }

    @Test("extracts waveform when metadata lacks one and skips when already provided")
    func waveformExtractionFallback() async throws {
        let engine = FakeAudioPlayerEngine()
        let controller = AudioPlaybackController(engine: engine, extractWaveform: { _, count in
            Array(repeating: 0.75, count: count)
        })
        let file = try makeTempAudioFile()
        defer { controller.stop() }

        controller.togglePlay(itemID: "plain-audio", announcedDuration: 4, isVoice: false, hasWaveform: false) { file }
        await waitUntil { controller.extractedWaveforms["plain-audio"] != nil }
        #expect(controller.extractedWaveforms["plain-audio"]?.count == WaveformResampler.defaultBarCount)
    }

    @Test("audioFilename adds extension for extensionless Element voice notes and preserves existing extensions")
    func audioFilenameExtensionInference() {
        #expect(TimelineViewModel.audioFilename(from: "Voice message", mimeType: "audio/ogg") == "Voice message.ogg")
        #expect(TimelineViewModel.audioFilename(from: "Voice message", mimeType: "audio/ogg; codecs=opus") == "Voice message.ogg")
        #expect(TimelineViewModel.audioFilename(from: "note", mimeType: "audio/mp4") == "note.m4a")
        #expect(TimelineViewModel.audioFilename(from: "already.m4a", mimeType: "audio/mp4") == "already.m4a")
        #expect(TimelineViewModel.audioFilename(from: "song.mp3", mimeType: "audio/mpeg") == "song.mp3")
        #expect(TimelineViewModel.audioFilename(from: "../escape", mimeType: "audio/ogg") == "escape.ogg")
    }

    @Test("TimelineViewModel sends voice messages with MSC3245/MSC1767 metadata and stops audio on room close")
    func timelineViewModelVoiceSendAndLifecycle() async throws {
        let room = try RoomID("!voice:example.org")
        let port = FakeTimelinePort()
        let media = FakeMediaPort()
        let ref = MediaRef(token: "voice-ref")
        media.add(ref, data: Data("fake-ogg".utf8))
        let item = TimelineItem(
            id: TimelineItemID("v1"),
            content: .event(TimelineEvent(
                eventID: try EventID("$v1"), sender: try UserID("@peer:example.org"), senderName: "Peer",
                timestamp: Date(timeIntervalSince1970: 100), isOwn: false,
                kind: .media(MediaAttachment(
                    kind: .audio, body: "Voice message", source: ref, mimeType: "audio/ogg",
                    size: 8, duration: 3, isVoice: true, waveform: [0.1, 0.9, 0.2])))))
        port.addRoom(room, items: [item])

        let engine = FakeAudioPlayerEngine()
        let player = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            media: MediaLoader(port: media),
            audioPlayer: player
        )
        await vm.start()

        // Send a voice recording with duration + waveform.
        await vm.sendVoice(data: Data([1, 2, 3, 4]), duration: 2.4, waveform: [0.2, 0.7, 0.5])
        let sent = port.sentFiles(in: room)
        #expect(sent.count == 1)
        #expect(sent[0].isVoiceMessage == true)
        #expect(sent[0].duration == 2.4)
        #expect(sent[0].waveform == [0.2, 0.7, 0.5])
        #expect(sent[0].mimeType == "audio/mp4")

        // Play the incoming voice row via TimelineViewModel, verify `.ogg` filename passed to engine, then stop on vm.stop().
        let row = vm.row(item)
        vm.toggleAudioPlayback(for: row)
        await waitUntil { vm.audioPlayer.phase == .playing }
        #expect(engine.loaded.first?.url.pathExtension == "ogg")

        await vm.stop()
        #expect(vm.audioPlayer.phase == .idle)
        #expect(vm.audioPlayer.activeID == nil)
    }

    @Test("real AVAudioPlayerEngine loads, reports duration, extracts waveform, seeks, and stops a real audio file")
    func realAVPlayerEngineSmoke() async throws {
        let wavURL = try makeRealWAVFile(durationSeconds: 0.6)
        defer { try? FileManager.default.removeItem(at: wavURL.deletingLastPathComponent()) }

        // Real AVAssetReader waveform extraction off the main actor.
        let bars = await AudioWaveformExtractor.extract(from: wavURL, barCount: 16)
        #expect(bars?.count == 16)
        #expect((bars?.max() ?? 0) > 0.5)

        // Real AVPlayer engine load + duration + play + rate + seek + pause + stop.
        let engine = AVAudioPlayerEngine()
        let (durations, durationContinuation) = AsyncStream<TimeInterval>.makeStream()
        engine.onEvent = { event in
            if case .durationKnown(let d) = event {
                durationContinuation.yield(d)
                durationContinuation.finish()
            }
        }
        try engine.load(url: wavURL, isVoice: true)
        try engine.play(rate: AudioPlaybackRate.onePointFive.rawValue)
        engine.setRate(AudioPlaybackRate.two.rawValue)
        engine.seek(to: 0.2)
        var measured: TimeInterval?
        for await value in durations {
            measured = value
            break
        }
        engine.pause()
        engine.stop()

        let duration = try #require(measured)
        #expect(duration > 0.4 && duration < 0.9)
    }

    @Test("real AVAudioPlayerEngine plays Element-format Ogg Opus (.ogg) voice notes on iOS 26 (M20-2 interop)")
    func realAVPlayerEnginePlaysOggOpusVoiceNote() async throws {
        // Real 0.6 s 48 kHz mono libopus Ogg audio clip (same container + codec as Element Web / Element X MSC3245 voice notes).
        let oggBase64 =
            "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"
        let oggData = try #require(Data(base64Encoded: oggBase64))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-ogg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filename = TimelineViewModel.audioFilename(from: "Voice message", mimeType: "audio/ogg")
        #expect(filename == "Voice message.ogg")
        let oggURL = dir.appendingPathComponent(filename)
        try oggData.write(to: oggURL)

        let engine = AVAudioPlayerEngine()
        let (events, continuation) = AsyncStream<AudioEngineEvent>.makeStream()
        engine.onEvent = { event in
            switch event {
            case .durationKnown, .failed:
                continuation.yield(event)
                continuation.finish()
            default:
                break
            }
        }
        try engine.load(url: oggURL, isVoice: true)
        try engine.play(rate: AudioPlaybackRate.onePointFive.rawValue)

        var firstOutcome: AudioEngineEvent?
        for await event in events {
            firstOutcome = event
            break
        }
        engine.stop()

        guard case .durationKnown(let measured) = firstOutcome else {
            Issue.record("Expected Ogg Opus duration, got \(String(describing: firstOutcome))")
            return
        }
        #expect(measured > 0.4 && measured < 0.9)
    }

    #if canImport(UIKit)
    @Test("AudioBubbleView lays out cleanly in Light, Dark, and AX5 across all states")
    func audioBubbleLayoutLightDarkAX5() async throws {
        let room = try RoomID("!ui:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let engine = FakeAudioPlayerEngine()
        let player = AudioPlaybackController(engine: engine, extractWaveform: { _, _ in nil })
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), audioPlayer: player)

        let voiceRow = TimelineRow(
            id: "voice-playing", style: .ownMessage, sender: "You", text: "[Voice message]",
            eventID: try EventID("$v1"), isOwn: true,
            audio: .init(
                ref: MediaRef(token: "v1"), name: "Voice message.m4a", mimeType: "audio/mp4",
                size: 42_000, duration: 24, isVoice: true,
                waveform: [0.15, 0.35, 0.72, 0.95, 0.60, 0.40, 0.85, 0.90, 0.30, 0.55, 0.80, 0.25, 0.45, 0.70, 0.50, 0.20]))
        let idleRow = TimelineRow(
            id: "voice-idle", style: .message, sender: "Alice", text: "[Voice message]",
            eventID: try EventID("$v2"), isOwn: false,
            audio: .init(
                ref: MediaRef(token: "v2"), name: "Voice message", mimeType: "audio/ogg",
                size: 18_500, duration: 9, isVoice: true,
                waveform: [0.2, 0.6, 0.8, 0.4, 0.9, 0.5, 0.3, 0.7]))
        let audioFileRow = TimelineRow(
            id: "audio-file", style: .message, sender: "Alice", text: "[Audio] podcast-clip.mp3",
            eventID: try EventID("$v3"), isOwn: false,
            audio: .init(
                ref: MediaRef(token: "v3"), name: "podcast-clip.mp3", mimeType: "audio/mpeg",
                size: 2_400_000, duration: 185, isVoice: false, waveform: nil))
        let errorRow = TimelineRow(
            id: "voice-error", style: .message, sender: "Alice", text: "[Voice message]",
            eventID: try EventID("$v4"), isOwn: false,
            audio: .init(ref: MediaRef(token: "v4"), name: "Voice message", mimeType: "audio/ogg", size: 12_000, duration: 5, isVoice: true))

        // Put `voice-playing` into active playing state at 1.5x, 40% through.
        let tempFile = try makeTempAudioFile()
        defer { player.stop() }
        player.togglePlay(itemID: voiceRow.id, announcedDuration: 24, isVoice: true, hasWaveform: true) { tempFile }
        await waitUntil { player.phase == .playing }
        player.cycleRate()
        engine.emit(.timeUpdated(9.6))

        // Separate VM in failed state for error-state visual check.
        let errEngine = FakeAudioPlayerEngine()
        let errPlayer = AudioPlaybackController(engine: errEngine, extractWaveform: { _, _ in nil })
        let errVM = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), audioPlayer: errPlayer)
        errPlayer.togglePlay(itemID: errorRow.id, announcedDuration: 5, isVoice: true, hasWaveform: false) {
            throw HaloError.network(retryable: true)
        }
        await waitUntil {
            if case .failed = errPlayer.phase { return true }
            return false
        }

        let voiceAudio = try #require(voiceRow.audio)
        let idleAudio = try #require(idleRow.audio)
        let fileAudio = try #require(audioFileRow.audio)
        let errorAudio = try #require(errorRow.audio)

        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_AUDIO_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(alignment: .leading, spacing: 14) {
                HStack { Spacer(); AudioBubbleView(row: voiceRow, audio: voiceAudio, model: vm, isOwn: true) }
                AudioBubbleView(row: idleRow, audio: idleAudio, model: vm, isOwn: false)
                AudioBubbleView(row: audioFileRow, audio: fileAudio, model: vm, isOwn: false)
                AudioBubbleView(row: errorRow, audio: errorAudio, model: errVM, isOwn: false)
            }
            .padding(16)
            .frame(width: 390, alignment: .leading)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = config.style
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 1200))
            #expect(fitted.width >= 350 && fitted.height >= 200)

            if let outDir {
                let renderer = ImageRenderer(content: content.frame(width: fitted.width, height: fitted.height))
                renderer.scale = 2
                if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("audio-bubble-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
    #endif
}
