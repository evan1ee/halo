import Foundation
import HaloDomain
import HaloFoundation

/// The share inbox on disk: one folder per payload with `manifest.json` and one file per staged item. The share extension
/// stages into it, the app reads from it; both use the same App Group directory (`HaloShared.shareInboxDirectory`).
/// A payload appears only when complete: it is written under a dot-prefixed name and renamed.
public struct FileShareInbox: ShareInboxPort {
    /// What the extension hands over for one item before it is staged.
    public enum Staged: Sendable {
        case text(String)
        case url(String)
        case file(data: Data, filename: String, mimeType: String, isImage: Bool)
    }

    /// An extension is killed past ~120 MB, and the app holds a file in memory to send it; stay under the file limit.
    public static let maximumPayloadBytes = OutgoingFile.maximumBytes

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    // MARK: Extension side

    /// Stages `items` as one payload. Throws `.invalidInput("SHARE_TOO_LARGE")` past `maximumPayloadBytes`, `.invalidInput("SHARE_EMPTY")` for nothing.
    @discardableResult
    public func stage(_ items: [Staged]) throws(HaloError) -> SharePayload {
        guard !items.isEmpty else { throw .invalidInput("SHARE_EMPTY") }
        let total = items.reduce(0) { sum, item in
            if case .file(let data, _, _, _) = item { sum + data.count } else { sum }
        }
        guard total <= Self.maximumPayloadBytes else { throw .invalidInput("SHARE_TOO_LARGE") }

        let id = UUID().uuidString
        let temporary = directory.appendingPathComponent(".\(id)", isDirectory: true)
        let final = directory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            var shared: [SharedItem] = []
            for item in items {
                switch item {
                case .text(let text):
                    shared.append(SharedItem(kind: .text, text: text))
                case .url(let url):
                    shared.append(SharedItem(kind: .url, text: url))
                case .file(let data, let filename, let mimeType, let isImage):
                    let entry = SharedItem(
                        kind: isImage ? .image : .file, filename: Self.safeName(filename), mimeType: mimeType, byteCount: data.count
                    )
                    try data.write(to: temporary.appendingPathComponent(entry.id), options: .completeFileProtectionUntilFirstUserAuthentication)
                    shared.append(entry)
                }
            }
            let payload = SharePayload(id: id, createdAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)), items: shared)  // whole seconds: the manifest must round-trip exactly
            try Self.encoder.encode(payload).write(to: temporary.appendingPathComponent("manifest.json"))
            try FileManager.default.moveItem(at: temporary, to: final)
            return payload
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw .invalidInput("SHARE_WRITE_FAILED")
        }
    }

    // MARK: ShareInboxPort

    public func pending() throws(HaloError) -> [SharePayload] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let current = now()
        var payloads: [SharePayload] = []
        for name in names {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix(".") {
                // An interrupted staging; nothing reads it, so it is removed once stale.
                if let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   current.timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: folder) }
                continue
            }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let payload = try? Self.decoder.decode(SharePayload.self, from: data) else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            if payload.isExpired(at: current) {
                try? FileManager.default.removeItem(at: folder)
            } else {
                payloads.append(payload)
            }
        }
        return payloads.sorted { $0.createdAt < $1.createdAt }
    }

    public func data(of item: SharedItem, in payload: SharePayload) throws(HaloError) -> Data {
        let url = directory.appendingPathComponent(payload.id, isDirectory: true).appendingPathComponent(item.id)
        guard payload.items.contains(item), let data = try? Data(contentsOf: url) else { throw .notFound }
        return data
    }

    public func discard(_ payload: SharePayload) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(payload.id, isDirectory: true))
    }

    // MARK: Helpers

    /// A file name without path parts, since it is shown and sent.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return last.isEmpty || last == ".." ? "file" : last
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
