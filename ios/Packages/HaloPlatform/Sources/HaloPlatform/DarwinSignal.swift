import Foundation

/// Cross-process Darwin notification signal for shared database changes (`one.mbm.halo.db.changed`,
/// docs/data/PERSISTENCE.md §4, D63). Used by the notification extension to wake the app after writing
/// `notification_record` rows to `halo.sqlite`.
public struct DarwinSignal: Sendable {
    public let name: String

    public init(name: String = "\(HaloShared.namespace()).db.changed") {
        self.name = name
    }

    public func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    public func observe() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let box = Unmanaged.passRetained(DarwinBox(continuation))
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), box.toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinBox>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
            }, name as CFString, nil, .deliverImmediately)
        let signalName = name
        let address = UInt(bitPattern: box.toOpaque())
        continuation.onTermination = { _ in
            let pointer = UnsafeRawPointer(bitPattern: address)
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), pointer, CFNotificationName(signalName as CFString), nil)
            if let pointer { Unmanaged<DarwinBox>.fromOpaque(pointer).release() }
        }
        return stream
    }
}

private final class DarwinBox {
    let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
}
