import Foundation
import HaloDomain
import HaloFoundation

/// Loads media for the UI with an in-memory cache and one download per reference at a time. The cache is
/// derived, rebuildable data (AGENTS.md §4.1); a disk cache arrives with M4's sticker work.
public actor MediaLoader {
    private struct Key: Hashable {
        let ref: MediaRef
        let width: Int
        let height: Int
    }

    private let port: any MediaPort
    private let byteLimit: Int
    private var cache: [Key: Data] = [:]
    /// Keys from least to most recently used.
    private var order: [Key] = []
    private var cachedBytes = 0
    private var inFlight: [Key: Task<Data, Error>] = [:]

    public init(port: any MediaPort, byteLimit: Int = 32 * 1024 * 1024) {
        self.port = port
        self.byteLimit = byteLimit
    }

    public func thumbnail(_ ref: MediaRef, width: Int, height: Int) async throws(HaloError) -> Data {
        let key = Key(ref: ref, width: width, height: height)
        if let data = cache[key] {
            touch(key)
            return data
        }
        let task: Task<Data, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let port = self.port
            task = Task { try await port.thumbnail(ref, width: width, height: height) }
            inFlight[key] = task
        }
        do {
            let data = try await task.value
            inFlight[key] = nil
            store(data, for: key)
            return data
        } catch {
            inFlight[key] = nil
            throw (error as? HaloError) ?? .internal(code: "MEDIA_LOAD")
        }
    }

    /// The full content, for a single large view such as a sticker preview. Not cached: it is read on demand.
    public func content(_ ref: MediaRef) async throws(HaloError) -> Data {
        do { return try await port.content(ref) } catch { throw error }
    }

    // MARK: Cache

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func store(_ data: Data, for key: Key) {
        guard data.count <= byteLimit else { return }  // too big to cache at all
        if let old = cache[key] { cachedBytes -= old.count }
        cache[key] = data
        cachedBytes += data.count
        touch(key)
        while cachedBytes > byteLimit, let oldest = order.first {
            order.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) { cachedBytes -= evicted.count }
        }
    }
}
