import Foundation
import HaloFoundation

/// One thing handed to Halo through the system share sheet (M16 share extension).
public struct SharedItem: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case text, url, image, file }

    public let id: String
    public let kind: Kind
    /// The text or the URL string; `nil` for an image or a file.
    public let text: String?
    /// The original file name; `nil` for text and URLs.
    public let filename: String?
    public let mimeType: String?
    /// The size of the staged file in bytes; `nil` for text and URLs.
    public let byteCount: Int?

    public init(id: String = UUID().uuidString, kind: Kind, text: String? = nil, filename: String? = nil, mimeType: String? = nil, byteCount: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }

    /// A short label for the picker ("Photo", "Link", …).
    public var summary: String {
        switch kind {
        case .text, .url: text ?? ""
        case .image, .file: filename ?? (kind == .image ? "Photo" : "File")
        }
    }
}

/// Items the extension staged for the app to send once the person picks a chat. The extension never talks to the
/// homeserver (it has no session and may not start sync, AGENTS §17); the app sends them through the normal timeline path.
public struct SharePayload: Sendable, Equatable, Codable, Identifiable {
    /// Staged payloads older than this are dropped unseen (the share is stale and the person has moved on).
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public let id: String
    public let createdAt: Date
    public let items: [SharedItem]

    public init(id: String = UUID().uuidString, createdAt: Date, items: [SharedItem]) {
        self.id = id
        self.createdAt = createdAt
        self.items = items
    }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince(createdAt) > Self.lifetime }
}

/// The App Group inbox between the share extension and the app. Implemented in `HaloPlatform` (files); faked in `HaloTestSupport`.
public protocol ShareInboxPort: Sendable {
    /// Staged payloads, oldest first, without expired ones (those are deleted).
    func pending() throws(HaloError) -> [SharePayload]
    /// The bytes of a staged file item.
    func data(of item: SharedItem, in payload: SharePayload) throws(HaloError) -> Data
    /// Deletes a payload and its files; a missing one is not an error.
    func discard(_ payload: SharePayload)
}
