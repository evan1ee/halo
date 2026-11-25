import Foundation
import Synchronization

/// What iOS measured about Halo itself (MetricKit: crashes, hangs, launch, CPU, memory, disk), kept on the device until the user exports
/// it with the diagnostics (D59, D114, LOGGING_AND_DIAGNOSTICS §4). Never uploaded. Bounded in age, count and size.
public final class MetricPayloadStore: Sendable {
    public enum Kind: String, Sendable, CaseIterable { case metrics, diagnostics }

    public struct Limits: Sendable {
        public var age: TimeInterval
        public var count: Int
        public var totalBytes: Int
        public var payloadBytes: Int

        public init(age: TimeInterval = 30 * 86_400, count: Int = 40, totalBytes: Int = 2 * 1_048_576, payloadBytes: Int = 512 * 1024) {
            self.age = age
            self.count = count
            self.totalBytes = totalBytes
            self.payloadBytes = payloadBytes
        }
    }

    public struct Stored: Sendable, Equatable {
        public let filename: String
        public let data: Data
    }

    private let directory: URL
    private let limits: Limits
    /// Payloads arrive on a background queue while an export may be reading.
    private let lock = Mutex(())

    public init(directory: URL, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
    }

    /// In the app's own container (not the App Group) and left out of backups: it describes this device only.
    public static func standardDirectory() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("diagnostics/metrickit", isDirectory: true)
    }

    /// Stores one payload's JSON after redaction; `false` when it isn't JSON, is too large or can't be written.
    @discardableResult
    public func save(_ json: Data, kind: Kind, at date: Date = Date()) -> Bool {
        guard let redacted = MetricPayloadRedaction.redact(json), redacted.count <= limits.payloadBytes else { return false }
        return lock.withLock { _ in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var folder = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                let name = "\(Self.stamp(date))-\(kind.rawValue)-\(UUID().uuidString.prefix(4)).json"
                try redacted.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                return false
            }
            prune(now: date)
            return true
        }
    }

    /// The stored payloads, oldest first; expired ones are removed first.
    public func all(now: Date = Date()) -> [Stored] {
        lock.withLock { _ in
            prune(now: now)
            return filenames().compactMap { name in
                (try? Data(contentsOf: directory.appendingPathComponent(name))).map { Stored(filename: name, data: $0) }
            }
        }
    }

    /// Filenames begin with the UTC time they were stored, so sorting them sorts by age.
    private func filenames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    private func prune(now: Date) {
        let oldest = Self.stamp(now.addingTimeInterval(-limits.age))
        var bytes = 0
        for (index, name) in filenames().reversed().enumerated() {  // newest first
            let file = directory.appendingPathComponent(name)
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= limits.count || bytes > limits.totalBytes || name < oldest { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }
}

/// Removes what a payload could carry beyond code locations and numbers (SECURITY §6): an exception's message may quote app data, so only
/// its type and name stay, and any text that looks like a Matrix identifier or a link is blanked wherever it stands.
enum MetricPayloadRedaction {
    static let placeholder = "<redacted>"
    private static let droppedKeys: Set<String> = ["composedMessage", "formatString", "arguments"]
    nonisolated(unsafe) private static let identifier = /[@!#$][^\s:]+:[A-Za-z0-9.\-\[\]]+|\$[A-Za-z0-9_\-]{20,}|(?i)(?:https?|mxc|matrix):\/{0,2}[^\s"]+/

    static func redact(_ json: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: json), object is [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean(object), options: [.sortedKeys])
    }

    private static func clean(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in object { result[key] = droppedKeys.contains(key) ? placeholder : clean(child) }
            return result
        case let array as [Any]:
            return array.map(clean)
        case let text as String:
            return text.replacing(identifier, with: placeholder)
        default:
            return value
        }
    }
}
