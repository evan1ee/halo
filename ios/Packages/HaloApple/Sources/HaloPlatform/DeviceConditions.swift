import Foundation
import Network
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// What background-like work looks at before it uses the device: power, heat, the kind of network. Reports changes.
public final class DeviceConditions: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var lowPower = false
        /// Thermal state serious or worse.
        public var isHot = false
        /// Cellular, a personal hotspot, or a network in Low Data Mode.
        public var onMobileData = false
        public var offline = false

        public init() {}
    }

    private let monitor = NWPathMonitor()
    private let path = Mutex((onMobileData: false, offline: false))
    private let changed: @Sendable () -> Void
    private let tasks = Mutex<[Task<Void, Never>]>([])

    public init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        monitor.pathUpdateHandler = { [weak self] path in
            self?.path.withLock { $0 = (path.isExpensive || path.isConstrained, path.status != .satisfied) }
            changed()
        }
        monitor.start(queue: DispatchQueue(label: "halo.device-conditions"))
        tasks.withLock { tasks in
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
                tasks.append(Task {
                    for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) { changed() }
                })
            }
        }
    }

    deinit {
        monitor.cancel()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    public var snapshot: Snapshot {
        let info = ProcessInfo.processInfo
        let path = path.withLock { $0 }
        var result = Snapshot()
        result.lowPower = info.isLowPowerModeEnabled
        result.isHot = info.thermalState == .serious || info.thermalState == .critical
        result.onMobileData = path.onMobileData
        result.offline = path.offline
        return result
    }
}

/// Whether files with `complete` protection can be opened (D124): not while the phone is locked.
public final class ProtectedData: Sendable {
    private let readable = Atomic(true)

    /// - Parameters:
    ///   - willLock: called shortly before the files close.
    ///   - didUnlock: called when they can be opened again.
    @MainActor
    public init(willLock: @escaping @Sendable () -> Void, didUnlock: @escaping @Sendable () -> Void) {
        #if os(iOS)
        // Not asked here: this early in a launch the answer is always "no". Until it is known, an open that iOS refuses says so itself.
        Task { @MainActor [weak self] in
            let available = UIApplication.shared.isProtectedDataAvailable
            self?.readable.store(available, ordering: .relaxed)
            if available { didUnlock() }
        }
        // The observers live as long as the app: one object, made at launch.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil) { [weak self] _ in
            self?.readable.store(false, ordering: .relaxed)
            willLock()
        }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { [weak self] _ in
            self?.readable.store(true, ordering: .relaxed)
            didUnlock()
        }
        #endif
    }

    public var isReadable: Bool { readable.load(ordering: .relaxed) }
}
