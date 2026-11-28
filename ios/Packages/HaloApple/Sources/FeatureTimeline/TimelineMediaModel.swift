import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Owns media playback, thumbnail caching, hidden-preview reveals, and file/video/photo download & export for a room (audit F-08).
@MainActor @Observable
public final class TimelineMediaModel {
    /// A file is written to disk as it arrives (M19-5), so the limit is disk and patience, not memory.
    public nonisolated static let openSizeLimit = 300 * 1024 * 1024
    /// Largest sticker file the timeline plays by itself (STICKERS FR-8/FR-9; the same limit as the panel).
    static let stickerAutoplayLimit = 1_000_000

    /// Owns inline playback of voice messages and audio files for this room so playback survives scrolling (MEDIA_ATTACHMENTS FR-3, M20-2).
    public let audioPlayer: AudioPlaybackController
    /// Pictures already shown (`TimelineThumbnailMemory`) and the photo reference last seen per row, to carry a sent photo
    /// from its local echo to the confirmed message.
    let thumbnailMemory: TimelineThumbnailMemory
    let media: MediaLoader?
    var knownPhotoRefs: [String: MediaRef] = [:]

    /// `true` when the account's media preview setting asks for a tap before photos/videos in this room are shown (FR-7).
    public internal(set) var previewsHidden = false
    var revealedPreviews: Set<MediaRef> = []

    var openFileTask: Task<Void, Never>?
    public internal(set) var openedFile: TimelineViewModel.OpenedFile?
    public internal(set) var openingRow: String?
    var openVideoTask: Task<Void, Never>?
    public internal(set) var openedVideo: TimelineViewModel.OpenedVideo?
    public internal(set) var openingVideoRow: String?
    public internal(set) var openFileError: String?

    public init(
        media: MediaLoader? = nil,
        thumbnails: TimelineThumbnailMemory? = nil,
        audioPlayer: AudioPlaybackController? = nil
    ) {
        self.media = media
        self.thumbnailMemory = thumbnails ?? TimelineThumbnailMemory()
        self.audioPlayer = audioPlayer ?? AudioPlaybackController()
    }

    public func stop() {
        cancelOpenFile()
        cancelOpenVideo()
        audioPlayer.stop()
    }

    /// Carries already-shown photo thumbnails from local echo references to confirmed server references.
    func adoptChangedPhotoReferences(rows: [TimelineRow]) {
        for change in TimelineThumbnailMemory.changedReferences(rows: rows, known: &knownPhotoRefs) {
            thumbnailMemory.adopt(change.old, as: change.new)
        }
    }

    // MARK: Previews

    public func showsPreview(of image: TimelineRow.Image) -> Bool { !previewsHidden || revealedPreviews.contains(image.ref) }
    public func revealPreview(of image: TimelineRow.Image) { revealedPreviews.insert(image.ref) }
    public func showsPreview(of video: TimelineRow.Video) -> Bool { !previewsHidden || revealedPreviews.contains(video.ref) }
    public func revealPreview(of video: TimelineRow.Video) { revealedPreviews.insert(video.ref) }

    // MARK: Opening files

    public func openFile(_ row: TimelineRow) async {
        let target: TimelineRow.FileTile?
        if let file = row.file {
            target = file
        } else if let audio = row.audio {
            target = TimelineRow.FileTile(
                kind: .audio, name: Self.audioFilename(from: audio.name, mimeType: audio.mimeType),
                detail: "", ref: audio.ref, size: audio.size, thumbnail: nil)
        } else if let video = row.video {
            target = TimelineRow.FileTile(
                kind: .video, name: VideoDisplayMetrics.videoFilename(from: video.filename, mimeType: video.mimeType),
                detail: "", ref: video.ref, size: video.size, thumbnail: video.thumbnail)
        } else {
            target = nil
        }
        guard let file = target, media != nil, openingRow == nil else { return }
        openFileError = nil
        if let size = file.size, size > Self.openSizeLimit {
            openFileError = "This file is too large to open here yet (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        openingRow = row.id
        let rowID = row.id
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.openingRow == rowID {
                    self.openingRow = nil
                    self.openFileTask = nil
                }
            }
            do {
                let url = try await self.downloadFileToTemp(file)
                if Task.isCancelled || self.openingRow != rowID {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())  // best-effort: cancelled download temp folder
                    return
                }
                self.openedFile = TimelineViewModel.OpenedFile(url: url)
            } catch is CancellationError {
                return
            } catch HaloError.cancelled {
                return
            } catch {
                guard !Task.isCancelled, self.openingRow == rowID else { return }
                self.openFileError = (error as? HaloError) == .network(retryable: true)
                    ? "Can't reach the server. The file wasn't opened."
                    : "The file couldn't be opened."
            }
        }
        openFileTask = task
        await task.value
    }

    public func cancelOpenFile() {
        openFileTask?.cancel()
        openFileTask = nil
        openingRow = nil
    }

    public func downloadFileToTemp(_ file: TimelineRow.FileTile) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = file.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("File exceeds the size limit")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try await media.file(file.ref, name: file.name, mimeType: nil, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)  // best-effort: a half-made temporary folder; the system clears the rest
            throw error
        }
    }

    public func closeFile() {
        if let url = openedFile?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        openedFile = nil
    }

    // MARK: Full-screen video playback (MEDIA_ATTACHMENTS FR-2, M19-5, M20-3)

    public func openVideo(_ row: TimelineRow) async {
        guard let video = row.video, media != nil, openingVideoRow == nil else { return }
        openFileError = nil
        if let size = video.size, size > Self.openSizeLimit {
            openFileError = "This video is too large to open here yet (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        audioPlayer.stop()
        openingVideoRow = row.id
        let rowID = row.id
        let title = row.isOwn ? "You" : (row.sender ?? "Video")
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.openingVideoRow == rowID {
                    self.openingVideoRow = nil
                    self.openVideoTask = nil
                }
            }
            do {
                let url = try await self.downloadVideoToTemp(video)
                if Task.isCancelled || self.openingVideoRow != rowID {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())  // best-effort: cancelled download temp folder
                    return
                }
                self.openedVideo = TimelineViewModel.OpenedVideo(url: url, title: title, caption: video.caption)
            } catch is CancellationError {
                return
            } catch HaloError.cancelled {
                return
            } catch {
                guard !Task.isCancelled, self.openingVideoRow == rowID else { return }
                self.openFileError = (error as? HaloError) == .network(retryable: true)
                    ? "Can't reach the server. The video wasn't opened."
                    : "The video couldn't be opened."
            }
        }
        openVideoTask = task
        await task.value
    }

    public func cancelOpenVideo() {
        openVideoTask?.cancel()
        openVideoTask = nil
        openingVideoRow = nil
    }

    public func closeVideo() {
        if let url = openedVideo?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        openedVideo = nil
    }

    public func downloadVideoToTemp(_ video: TimelineRow.Video) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = video.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("Video exceeds the size limit")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = VideoDisplayMetrics.videoFilename(from: video.filename, mimeType: video.mimeType)
        do {
            return try await media.file(video.ref, name: filename, mimeType: video.mimeType, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)  // best-effort: half-made temporary folder
            throw error
        }
    }

    // MARK: Inline audio and voice playback (MEDIA_ATTACHMENTS FR-3, M20-2)

    public func toggleAudioPlayback(for row: TimelineRow) {
        guard let audio = row.audio else { return }
        audioPlayer.togglePlay(
            itemID: row.id,
            announcedDuration: audio.duration,
            isVoice: audio.isVoice,
            hasWaveform: audio.waveform != nil
        ) { [weak self] in
            guard let self else { throw HaloError.cancelled }
            return try await self.downloadAudioToTemp(audio)
        }
    }

    public func downloadAudioToTemp(_ audio: TimelineRow.Audio) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = audio.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("Audio exceeds the size limit")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = Self.audioFilename(from: audio.name, mimeType: audio.mimeType)
        do {
            return try await media.file(audio.ref, name: filename, mimeType: audio.mimeType, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)  // best-effort: half-made temporary folder
            throw error
        }
    }

    static func audioFilename(from rawName: String, mimeType: String?) -> String {
        let last = rawName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let base = last.isEmpty || last == "." || last == ".." ? "audio" : last
        let existingExt = (base as NSString).pathExtension.lowercased()
        let knownAudioExtensions: Set<String> = ["m4a", "mp4", "ogg", "oga", "opus", "mp3", "wav", "aac", "caf", "flac", "aiff", "aif", "webm"]
        if knownAudioExtensions.contains(existingExt) { return base }

        let mime = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let inferredExt: String = switch mime {
        case "audio/ogg", "application/ogg", "audio/opus": "ogg"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/x-caf", "audio/caf": "caf"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/webm": "webm"
        default: ""
        }
        guard !inferredExt.isEmpty else { return base }
        return "\(base).\(inferredExt)"
    }

    public func dismissOpenFileError() { openFileError = nil }

    // MARK: Thumbnails, stickers, avatars, and viewer photos

    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 64, height: 64)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    public func stickerContent(for image: TimelineRow.Image) async -> Data? {
        guard let media, let full = try? await media.content(image.ref), full.count <= Self.stickerAutoplayLimit else { return nil }  // best-effort: a picture that can't load shows its placeholder; nothing changes
        return full
    }

    public func thumbnail(for image: TimelineRow.Image) async -> Data? {
        if let known = thumbnailMemory.data(for: image.ref) { return known }
        guard let media else { return nil }
        let loaded: Data?
        if let thumbRef = image.thumbnailRef, let direct = try? await media.cachedContent(thumbRef) {  // best-effort: falls back to server thumbnail
            loaded = direct
        } else if image.isOwn, let ownCached = try? await media.cachedContent(image.ref) {  // best-effort: SDK caches own uploads under MediaFormat::File (M19-5)
            loaded = ownCached
        } else {
            loaded = try? await media.thumbnail(image.ref, width: 600, height: 600)  // best-effort: a picture that can't load shows its placeholder; nothing changes
        }
        guard let loaded else { return nil }
        thumbnailMemory.store(loaded, for: image.ref)
        return loaded
    }

    func cachedThumbnail(for image: TimelineRow.Image) -> Data? { thumbnailMemory.data(for: image.ref) }

    public func fullImageFile(for image: TimelineRow.Image, filename: String = "photo.jpg") async -> URL? {
        guard let media else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-viewer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = Self.photoFilename(from: filename)
            if let url = try? await media.file(image.ref, name: safeName, mimeType: nil, in: dir) {  // best-effort: falls back to thumbnail
                return url
            }
            if let thumb = try? await media.thumbnail(image.ref, width: 1200, height: 1200) {  // best-effort: fallback preview
                let url = dir.appendingPathComponent(safeName)
                try thumb.write(to: url, options: .atomic)
                return url
            }
            try? FileManager.default.removeItem(at: dir)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    public func fullImageData(for image: TimelineRow.Image) async -> Data? {
        guard let url = await fullImageFile(for: image) else { return nil }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try? Data(contentsOf: url)
    }

    public func exportViewerPhoto(_ item: TimelineViewModel.PhotoViewerItem) async -> URL? {
        guard let media else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-photo-\(UUID().uuidString)", isDirectory: true)
        let filename = Self.photoFilename(from: item.caption ?? "photo.jpg")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let url = try? await media.file(item.image.ref, name: filename, mimeType: nil, in: dir) {  // best-effort: falls back to thumbnail export
                return url
            }
            if let thumb = try? await media.thumbnail(item.image.ref, width: 1200, height: 1200) {  // best-effort: caller handles nil export URL
                let url = dir.appendingPathComponent(filename)
                try thumb.write(to: url, options: .atomic)
                return url
            }
            try? FileManager.default.removeItem(at: dir)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    private static func photoFilename(from rawName: String) -> String {
        let raw = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let base = raw.isEmpty ? "photo.jpg" : raw
        return base.contains(".") ? base : "\(base).jpg"
    }
}
