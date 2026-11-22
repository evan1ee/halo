import Foundation
import HaloFoundation

/// One message entry in an on-demand encrypted room export archive (D32, R-P2-EXPORT).
public struct RoomExportMessage: Sendable, Equatable, Codable, Identifiable {
    public let eventID: String
    public let senderID: String?
    public let senderName: String
    public let timestamp: Date
    /// Message kind label (`text`, `notice`, `emote`, `image`, `video`, `audio`, `file`, `sticker`, `redacted`, etc.).
    public let kind: String
    public let body: String
    public let mediaFilename: String?

    public var id: String { eventID }

    public init(
        eventID: String,
        senderID: String?,
        senderName: String,
        timestamp: Date,
        kind: String,
        body: String,
        mediaFilename: String? = nil
    ) {
        self.eventID = eventID
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.mediaFilename = mediaFilename
    }
}

/// Plaintext payload serialized inside an encrypted room export archive (D32, R-P2-EXPORT).
public struct RoomExportDocument: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let roomID: String
    public let roomName: String
    public let roomTopic: String?
    public let messages: [RoomExportMessage]

    public init(
        version: Int = RoomExportDocument.currentVersion,
        exportedAt: Date,
        roomID: String,
        roomName: String,
        roomTopic: String?,
        messages: [RoomExportMessage]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.roomID = roomID
        self.roomName = roomName
        self.roomTopic = roomTopic
        self.messages = messages
    }
}

/// Encrypts and decrypts on-demand room export archives with a user-chosen passphrase (D32, R-P2-EXPORT).
/// Implemented in `HaloPlatform` with CryptoKit + PBKDF2-HMAC-SHA256 / AES-256-GCM.
public protocol RoomExportEncryptor: Sendable {
    /// Minimum passphrase length enforced before deriving an encryption key.
    static var minimumPassphraseLength: Int { get }

    func encrypt(_ plaintext: Data, passphrase: String) throws(HaloError) -> Data
    func decrypt(_ archive: Data, passphrase: String) throws(HaloError) -> Data
}

extension RoomExportEncryptor {
    public static var minimumPassphraseLength: Int { 8 }
}
