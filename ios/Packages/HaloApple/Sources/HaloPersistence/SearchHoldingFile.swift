import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// What was read for search while the phone was locked (D124): encrypted, readable after the first unlock, until it moves into the index.
/// A second file holds, equally encrypted, what a processing task may read next, because the index can't say while it is locked.
final class SearchHoldingFile: Sendable {
    static let plannedWork = 200
    /// Beyond this nothing more is held; the history lane reads it again later.
    static let maximumBytes = 50_000_000

    private let operations: URL
    private let planned: URL
    private let cipher: FieldCipher
    private let lock = Mutex(())

    init(directory: URL, cipher: FieldCipher) {
        operations = directory.appendingPathComponent("search-holding")
        planned = directory.appendingPathComponent("search-plan")
        self.cipher = cipher
    }

    /// One encrypted line per call. Throws `.storage(.unavailable)` when full.
    func append(_ new: [SearchIndexOperation]) throws(HaloError) {
        let line = try encode(new)
        try lock.withLock { _ throws(HaloError) in
            let size = ((try? FileManager.default.attributesOfItem(atPath: operations.path))?[.size] as? NSNumber)?.intValue ?? 0
            guard size + line.count < Self.maximumBytes else { throw .storage(.unavailable) }
            do {
                if size == 0 { try write(Data(), to: operations) }
                let handle = try FileHandle(forWritingTo: operations)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line + Data("\n".utf8))
            } catch { throw .storage(.unavailable) }
        }
        advancePlan(by: new)
    }

    /// Everything held, in order. A line that can't be read (cut off by a crash) is left out.
    func take() -> [[SearchIndexOperation]] {
        lock.withLock { _ in
            guard let data = try? Data(contentsOf: operations) else { return [] }
            return data.split(separator: UInt8(ascii: "\n")).compactMap { decode([SearchIndexOperation].self, Data($0)) }
        }
    }

    func clear() {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: operations)
            try? FileManager.default.removeItem(at: planned)
        }
    }

    func save(plan: [SearchHistoryWork]) {
        let stored = plan.compactMap { work -> PlannedWork? in
            switch work {
            case .start(let room): PlannedWork(room: room, before: nil)
            case .history(let room, let event): PlannedWork(room: room, before: event)
            case .check, .gap, .retry: nil  // need the index
            }
        }
        guard let data = try? encode(stored) else { return }
        lock.withLock { _ in try? write(data, to: planned) }
    }

    func plan() -> [SearchHistoryWork] {
        let data = lock.withLock { _ in try? Data(contentsOf: planned) }
        guard let data, let stored = decode([PlannedWork].self, data) else { return [] }
        return stored.map { work in work.before.map { .history(work.room, before: $0) } ?? .start(work.room) }
    }

    private struct PlannedWork: Codable {
        let room: RoomID
        let before: EventID?
    }

    private func advancePlan(by new: [SearchIndexOperation]) {
        var current = plan()
        for operation in new {
            switch operation {
            case .slice(let slice, .history(let room)):
                guard let index = current.firstIndex(where: { $0.room == room }) else { continue }
                if slice.reachedStart { current.remove(at: index) } else if let oldest = slice.oldest, current[index] != .history(room, before: oldest) {
                    current[index] = .history(room, before: oldest)
                } else { current.remove(at: index) }
            case .blocked(let room): current.removeAll { $0.room == room }
            default: continue
            }
        }
        save(plan: current)
    }

    /// Readable after the first unlock, so a processing task can add to it while the phone is locked; the contents are encrypted.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func encode(_ value: some Encodable) throws(HaloError) -> Data {
        guard let json = try? JSONEncoder().encode(value) else { throw .internal(code: "SEARCH_HOLDING") }
        return Data(try cipher.encrypt(String(decoding: json, as: UTF8.self)).utf8)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) -> Value? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix(FieldCipher.versionPrefix), let json = try? cipher.decrypt(text) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
