import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPersistence
import HaloPlatform
import UserNotifications

/// Notification service extension (docs/matrix/PUSH_NOTIFICATIONS.md §3, gate G-NSE, ADR-0016). A push is only a hint
/// (D65): this fetches the event it points at through the SDK, decrypts it, records it in `halo.sqlite`
/// (`notification_record`, R-13), and rewrites the notification with the sender and text. It never sets `aps.badge`
/// from a payload and never creates attention from a payload (AGENTS.md §17).
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private let lock = NSLock()
    private var delivered = false

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        let info = request.content.userInfo
        guard let roomRaw = info["room_id"] as? String, let eventRaw = info["event_id"] as? String,
              let room = try? RoomID(roomRaw), let event = try? EventID(eventRaw) else {
            deliver(request.content, outcome: "no-event", metrics: NSEMetrics())  // PUSH_NO_EVENT: nothing to fetch
            return
        }
        // UserNotifications types aren't Sendable; the request is only read by `run`, which delivers exactly once.
        nonisolated(unsafe) let request = request
        Task { await self.run(room: room, event: event, request: request) }
    }

    /// iOS is about to kill the extension: deliver the generic content (no message text) now.
    override func serviceExtensionTimeWillExpire() {
        if let original { deliver(original, outcome: "timeout", metrics: NSEMetrics()) }
    }

    private func run(room: RoomID, event: EventID, request: UNNotificationRequest) async {
        var metrics = NSEMetrics()
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.badge = nil  // the badge is never taken from a push (ADR-0015); it is set below from local state
        let suite = "group.\(HaloShared.namespace())"
        do {
            guard let data = try await HaloShared.keychain().read(.session) else { return deliver(request.content, outcome: "no-session", metrics: metrics) }
            let stored = try JSONDecoder().decode(StoredSession.self, from: data)
            metrics.step("keychain")
            let directory = HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try HaloDatabase(path: directory.appendingPathComponent("halo.sqlite").path)
            let signal = DarwinSignal()
            let records = NotificationRecordStore(database: database, account: stored.userID, onChange: { signal.post() })
            let session = MatrixSessionPort(baseDirectory: HaloShared.storeDirectory(), holderName: "nse", sendsMessages: false, lightweightRuntime: true)
            try await session.restore(stored)
            metrics.step("restore")
            let result = try await MatrixNotificationPort(session: session).fetch(room: room, event: event)
            metrics.step("fetch")
            let now = Date()
            switch result {
            case .display(let display):
                content.title = display.title
                content.body = display.body
                content.threadIdentifier = room.rawValue
                records.add(NotificationRecord(
                    roomID: room, eventID: event, timestamp: display.timestamp ?? now,
                    isMention: display.isMention, deliveredAt: now, source: .nse))
                content.badge = NSNumber(value: badge(suite: suite, records: records))
                deliver(content, outcome: "display", metrics: metrics)
            case .encrypted(let roomName, let timestamp):
                content.title = roomName ?? "Halo"
                content.body = "Encrypted message"
                content.threadIdentifier = room.rawValue
                records.add(NotificationRecord(
                    roomID: room, eventID: event, timestamp: timestamp ?? now,
                    isMention: false, deliveredAt: now, source: .nse))
                content.badge = NSNumber(value: badge(suite: suite, records: records))
                deliver(content, outcome: "encrypted", metrics: metrics)
            case .suppressed:
                // Suppression needs Apple's filtering entitlement (V-PUSH-3); until then show the generic alert.
                deliver(request.content, outcome: "suppressed", metrics: metrics)
            }
        } catch {
            deliver(request.content, outcome: "error", metrics: metrics)
        }
    }

    /// The rooms the app last found to need attention plus every room with a notification record (the same union the app
    /// computes, UNREAD_STATE §2/C5). A fallback for when the extension can't recompute every room (V-NSE-2).
    private func badge(suite: String, records: NotificationRecordStore) -> Int {
        AttentionCache(suiteName: suite).rooms().union(records.all().map(\.roomID.rawValue)).count
    }

    private func deliver(_ content: UNNotificationContent, outcome: String, metrics: NSEMetrics) {
        lock.lock()
        let already = delivered
        delivered = true
        lock.unlock()
        guard !already else { return }
        metrics.write(outcome: outcome, appGroup: "group.\(HaloShared.namespace())")
        handler?(content)
    }
}
