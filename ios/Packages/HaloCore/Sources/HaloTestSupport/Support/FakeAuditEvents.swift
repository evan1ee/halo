import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `AuditEventPort` with the same cap as the database.
public final class FakeAuditEvents: AuditEventPort {
    public static let capacity = 5_000
    private let store = Mutex<[AuditEvent]>([])

    public init() {}

    public var events: [AuditEvent] { store.withLock { $0 } }

    public func append(_ events: [AuditEvent]) async throws(HaloError) {
        store.withLock { rows in
            rows.append(contentsOf: events)
            if rows.count > Self.capacity { rows.removeFirst(rows.count - Self.capacity) }
        }
    }

    public func all() async throws(HaloError) -> [AuditEvent] { events }

    public func unexplainedCount() async throws(HaloError) -> Int { events.filter { $0.finding.kind == .unexplained }.count }
}
