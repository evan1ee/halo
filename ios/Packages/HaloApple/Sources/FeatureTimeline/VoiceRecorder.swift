#if canImport(UIKit)
import AVFoundation
import Foundation
import Observation

/// Records a voice message for the composer's mic button (docs/features/COMPOSER_PANELS.md §2a, D99).
///
/// Tap the mic to start, tap send to finish and send, or cancel. The recording is AAC in an `.m4a` file in the app's
/// temporary directory (file protection applies), read once for sending and then deleted; it is sent through the
/// timeline's file path, so it is an `m.audio` upload, encrypted in encrypted rooms. Nothing is recorded before the
/// user taps the mic, and the system microphone permission is asked for then.
@MainActor @Observable
final class VoiceRecorder {
    enum Phase: Equatable { case idle, recording, denied, failed }

    private(set) var phase = Phase.idle
    private(set) var elapsed: TimeInterval = 0
    /// Longest voice message; recording stops and keeps what it has.
    static let maximumDuration: TimeInterval = 300

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?

    var isRecording: Bool { phase == .recording }

    /// "0:07", "1:23".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// Asks for the microphone if needed, then starts recording. Returns `false` when denied or the session failed.
    @discardableResult
    func start() async -> Bool {
        guard phase != .recording else { return true }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .denied
            return false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record(forDuration: Self.maximumDuration) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            fileURL = url
            elapsed = 0
            phase = .recording
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime > 0 ? recorder.currentTime : self.elapsed
                }
            }
            return true
        } catch {
            phase = .failed
            cleanUp()
            return false
        }
    }

    /// Stops and returns the recording (`nil` when shorter than half a second); the file is deleted.
    func finish() -> (data: Data, duration: TimeInterval)? {
        guard phase == .recording, let recorder, let url = fileURL else { return nil }
        let duration = max(recorder.currentTime, elapsed)
        recorder.stop()
        defer { cleanUp() }
        phase = .idle
        guard duration >= 0.5, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (data, duration)
    }

    /// Stops and throws the recording away.
    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        phase = .idle
        cleanUp()
    }

    func dismissProblem() { if phase == .denied || phase == .failed { phase = .idle } }

    private func cleanUp() {
        ticker?.cancel()
        ticker = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        recorder = nil
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
