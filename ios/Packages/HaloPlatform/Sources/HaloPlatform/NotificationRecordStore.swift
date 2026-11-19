import Foundation
import HaloDomain
import HaloFoundation

/// `NotificationRecordPort` in the App Group's `UserDefaults`, with a Darwin notification so the app notices what the
/// extension wrote. Records older than a week are dropped and at most 200 are kept. A Halo database table replaces this
/// when the unread persistence lands (UNREAD_STATE §8, M3). Read-modify-write isn't atomic across processes; a lost
/// record only costs one badge update, which the next sync or push repairs.
public struct NotificationRecordStore: NotificationRecordPort {
    private let suiteName: String
    private static let key = "notificationRecords.v1"
    private static let maximumCount = 200
    private static let maximumAge: TimeInterval = 7 * 24 * 3600
    private let darwinName: String

    public init(suiteName: String) {
        self.suiteName = suiteName
        darwinName = "\(suiteName).notification-records"
    }

    public func all() -> [NotificationRecord] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([NotificationRecord].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        return records.filter { $0.timestamp >= cutoff }
    }

    @discardableResult
    public func add(_ record: NotificationRecord) -> Bool {
        var records = all()
        guard !records.contains(where: { $0.eventID == record.eventID }) else { return false }
        records.append(record)
        write(Array(records.suffix(Self.maximumCount)))
        return true
    }

    public func clear(room: RoomID) {
        let records = all()
        let kept = records.filter { $0.roomID != room }
        if kept.count != records.count { write(kept) }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let box = Unmanaged.passRetained(DarwinBox(continuation))
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), box.toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinBox>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
            }, darwinName as CFString, nil, .deliverImmediately)
        let name = darwinName
        let address = UInt(bitPattern: box.toOpaque())
        continuation.onTermination = { _ in
            let pointer = UnsafeRawPointer(bitPattern: address)
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), pointer, CFNotificationName(name as CFString), nil)
            if let pointer { Unmanaged<DarwinBox>.fromOpaque(pointer).release() }
        }
        return stream
    }

    private func write(_ records: [NotificationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: Self.key)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinName as CFString), nil, nil, true)
    }
}

private final class DarwinBox {
    let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
}
