import Foundation
import HaloDomain
import HaloFoundation

/// Forwards text, media, files, stickers and locations to one or more chats (MESSAGING FR-8, AC-M4, M20-6).
///
/// Downloads/decrypts source media once (streaming videos/audio/files to disk, never whole in memory, M19-5)
/// and sends through each target room's `TimelineSession`, so the SDK freshly encrypts media and messages
/// for every encrypted destination. Partial failures are returned per room so the UI reports honestly and can retry.
public actor ForwardCoordinator {
    private let timeline: any TimelinePort
    private let media: any MediaPort
    private let temporaryDirectory: URL

    public init(
        timeline: any TimelinePort,
        media: any MediaPort,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.timeline = timeline
        self.media = media
        self.temporaryDirectory = temporaryDirectory
    }

    /// Forwards `payload` to each unique room in `targets`, preserving order.
    public func forward(_ payload: ForwardPayload, to targets: [RoomID]) async -> ForwardOutcome {
        var uniqueTargets: [RoomID] = []
        var seen: Set<RoomID> = []
        for room in targets where seen.insert(room).inserted {
            uniqueTargets.append(room)
        }
        guard !uniqueTargets.isEmpty else {
            return ForwardOutcome(succeeded: [], failed: [:])
        }

        let stagingDir = temporaryDirectory.appendingPathComponent("halo-forward-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let prepared: PreparedForward
        do {
            prepared = try await prepare(payload, in: stagingDir)
        } catch {
            var failures: [RoomID: HaloError] = [:]
            for room in uniqueTargets { failures[room] = error }
            return ForwardOutcome(succeeded: [], failed: failures)
        }

        var succeeded: [RoomID] = []
        var failed: [RoomID: HaloError] = [:]
        for room in uniqueTargets {
            do {
                let session = try await timeline.open(room: room)
                try await send(prepared, to: room, using: session)
                succeeded.append(room)
            } catch {
                failed[room] = error
            }
        }
        return ForwardOutcome(succeeded: succeeded, failed: failed)
    }

    private enum PreparedForward {
        case text(String)
        case image(OutgoingImage)
        case file(OutgoingFile)
        case sticker(body: String, url: String, info: StickerInfo?)
        case location(OutgoingLocation)
    }

    private func prepare(_ payload: ForwardPayload, in stagingDir: URL) async throws(HaloError) -> PreparedForward {
        switch payload {
        case .text(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
            return .text(body)

        case .image(let ref, let filename, let mimeType, let width, let height, let caption):
            let bytes = try await media.content(ref)
            let mime = mimeType ?? Self.sniffImageMIME(bytes) ?? "image/jpeg"
            let safeName = Self.safeFilename(filename, fallback: "photo.jpg")
            let image = OutgoingImage(
                data: bytes,
                filename: safeName,
                mimeType: mime,
                width: width,
                height: height,
                caption: caption
            )
            try image.validate()
            return .image(image)

        case .video(let ref, let filename, let mimeType, let duration, let width, let height, let caption, let thumbnailRef):
            do {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            } catch {
                throw .storage(.unavailable)
            }
            let safeName = VideoDisplayMetrics.videoFilename(from: filename, mimeType: mimeType ?? "video/mp4")
            let fileURL = try await media.file(ref, name: safeName, mimeType: mimeType, in: stagingDir)
            var thumb: OutgoingImage.Thumbnail?
            if let thumbnailRef, let thumbData = try? await media.content(thumbnailRef), !thumbData.isEmpty {  // best-effort: video forwards even if poster thumbnail fails
                thumb = OutgoingImage.Thumbnail(
                    data: thumbData,
                    mimeType: Self.sniffImageMIME(thumbData) ?? "image/jpeg",
                    width: width ?? 600,
                    height: height ?? 600
                )
            }
            let outgoing = OutgoingFile(
                data: Data(),
                filename: safeName,
                mimeType: mimeType ?? "video/mp4",
                duration: duration,
                fileURL: fileURL,
                width: width,
                height: height,
                caption: caption,
                thumbnail: thumb
            )
            try outgoing.validate()
            return .file(outgoing)

        case .audio(let ref, let filename, let mimeType, let duration, let isVoice, let waveform):
            do {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            } catch {
                throw .storage(.unavailable)
            }
            let safeName = Self.safeFilename(filename, fallback: isVoice ? "Voice message.m4a" : "audio.m4a")
            let fileURL = try await media.file(ref, name: safeName, mimeType: mimeType, in: stagingDir)
            let outgoing = OutgoingFile(
                data: Data(),
                filename: safeName,
                mimeType: mimeType ?? "audio/mp4",
                duration: duration,
                waveform: waveform,
                isVoiceMessage: isVoice,
                fileURL: fileURL
            )
            try outgoing.validate()
            return .file(outgoing)

        case .file(let ref, let filename, let mimeType):
            do {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            } catch {
                throw .storage(.unavailable)
            }
            let safeName = Self.safeFilename(filename, fallback: "file")
            let fileURL = try await media.file(ref, name: safeName, mimeType: mimeType, in: stagingDir)
            let outgoing = OutgoingFile(
                data: Data(),
                filename: safeName,
                mimeType: mimeType ?? "application/octet-stream",
                fileURL: fileURL
            )
            try outgoing.validate()
            return .file(outgoing)

        case .sticker(let body, let url, let info):
            guard url.hasPrefix("mxc://") else { throw .invalidInput("INVALID_STICKER_URL") }
            return .sticker(body: body, url: url, info: info)

        case .location(let location):
            try location.validate()
            return .location(location)
        }
    }

    private func send(_ prepared: PreparedForward, to room: RoomID, using session: any TimelineSession) async throws(HaloError) {
        switch prepared {
        case .text(let body):
            try await session.send(text: body, mentions: [])
        case .image(let image):
            try await session.sendImage(image)
        case .file(let file):
            try await session.sendFile(file)
        case .sticker(let body, let url, let info):
            let sticker = Sticker(
                pack: PackRef(room: room, stateKey: ""),
                shortcode: body.isEmpty ? "sticker" : body,
                body: body.isEmpty ? nil : body,
                url: url,
                info: info
            )
            try await session.sendSticker(sticker)
        case .location(let location):
            try await session.sendLocation(location)
        }
    }

    private static func safeFilename(_ name: String, fallback: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? fallback : trimmed
    }

    private static func sniffImageMIME(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }
}
