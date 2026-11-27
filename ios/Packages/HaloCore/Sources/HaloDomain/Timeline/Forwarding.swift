import Foundation
import HaloFoundation

/// A chat that a message can be forwarded to (MESSAGING FR-8, M20-6).
public struct ForwardTarget: Sendable, Equatable, Identifiable {
    public let id: RoomID
    public let name: String
    public let isDirect: Bool
    public let isEncrypted: Bool
    public let avatar: MediaRef?

    public init(id: RoomID, name: String, isDirect: Bool = false, isEncrypted: Bool, avatar: MediaRef? = nil) {
        self.id = id
        self.name = name
        self.isDirect = isDirect
        self.isEncrypted = isEncrypted
        self.avatar = avatar
    }
}

/// Forwardable content extracted from a timeline message (MESSAGING FR-8, AC-M4, M20-6).
///
/// Media variants hold their source `MediaRef` so `ForwardCoordinator` downloads/decrypts once
/// and uploads cleanly into each target room (re-encrypted by the SDK for encrypted targets).
public enum ForwardPayload: Sendable, Equatable {
    case text(String)
    case image(ref: MediaRef, filename: String, mimeType: String?, width: Int?, height: Int?, caption: String?)
    case video(
        ref: MediaRef, filename: String, mimeType: String?, duration: TimeInterval?,
        width: Int?, height: Int?, caption: String?, thumbnailRef: MediaRef?
    )
    case audio(
        ref: MediaRef, filename: String, mimeType: String?, duration: TimeInterval?,
        isVoice: Bool, waveform: [Float]?
    )
    case file(ref: MediaRef, filename: String, mimeType: String?)
    case sticker(body: String, url: String, info: StickerInfo?)
    case location(OutgoingLocation)

    /// Short one-line summary for the Forward sheet header and VoiceOver.
    public var previewSummary: String {
        switch self {
        case .text(let body):
            let single = body
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return single.isEmpty ? "Message" : single
        case .image(_, _, _, _, _, let caption):
            if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return caption }
            return "Photo"
        case .video(_, _, _, _, _, _, let caption, _):
            if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return caption }
            return "Video"
        case .audio(_, let filename, _, _, let isVoice, _):
            return isVoice ? "Voice message" : filename
        case .file(_, let filename, _):
            return filename
        case .sticker(let body, _, _):
            return body.isEmpty ? "Sticker" : "Sticker: \(body)"
        case .location(let location):
            return location.body
        }
    }

    /// SF Symbol name representing this payload kind.
    public var systemImage: String {
        switch self {
        case .text: "text.bubble"
        case .image: "photo"
        case .video: "video"
        case .audio(_, _, _, _, let isVoice, _): isVoice ? "waveform" : "music.note"
        case .file: "doc"
        case .sticker: "face.smiling"
        case .location: "mappin.and.ellipse"
        }
    }
}

/// Pure policy governing encryption-downgrade warnings when forwarding messages (MESSAGING FR-8, M20-6).
public enum ForwardPolicy {
    /// Targets that are unencrypted when the source chat is encrypted.
    public static func unencryptedTargetsLeavingEncryption(
        sourceIsEncrypted: Bool,
        targets: [ForwardTarget]
    ) -> [ForwardTarget] {
        guard sourceIsEncrypted else { return [] }
        return targets.filter { !$0.isEncrypted }
    }

    /// Human-readable warning naming the unencrypted destination(s), or `nil` when no encryption is being left.
    public static func encryptionWarning(
        sourceIsEncrypted: Bool,
        targets: [ForwardTarget]
    ) -> String? {
        let exposed = unencryptedTargetsLeavingEncryption(sourceIsEncrypted: sourceIsEncrypted, targets: targets)
        guard !exposed.isEmpty else { return nil }
        if exposed.count == 1, let only = exposed.first {
            return "You're forwarding from an encrypted chat to \"\(only.name)\", which isn't encrypted. Messages there can be read by the server."
        }
        let names = exposed.prefix(3).map(\.name).joined(separator: ", ")
        let suffix = exposed.count > 3 ? " and \(exposed.count - 3) more" : ""
        return "You're forwarding from an encrypted chat to \(exposed.count) unencrypted chats (\(names)\(suffix)). Messages there can be read by the server."
    }
}

/// Per-target result of forwarding a payload to one or more chats (M20-6).
public struct ForwardOutcome: Sendable, Equatable {
    public let succeeded: [RoomID]
    public let failed: [RoomID: HaloError]

    public init(succeeded: [RoomID], failed: [RoomID: HaloError]) {
        self.succeeded = succeeded
        self.failed = failed
    }

    public var isCompleteSuccess: Bool { failed.isEmpty && !succeeded.isEmpty }
    public var failedRoomIDs: [RoomID] { Array(failed.keys) }
}
