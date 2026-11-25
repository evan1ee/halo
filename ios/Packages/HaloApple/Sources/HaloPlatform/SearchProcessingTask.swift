import Foundation
import HaloDomain
import HaloFoundation
#if os(iOS)
import BackgroundTasks

/// Asks iOS for time on the charger to read more history for search (BACKGROUND_EXECUTION, MESSAGE_SEARCH FR-10). iOS decides when.
public enum SearchProcessingTask {
    /// A `BGProcessingTask` is used from one task only.
    private struct Box: @unchecked Sendable { let task: BGProcessingTask }  // BGTask's methods may be called from any thread (Apple's documentation)

    public static func identifier(bundle: Bundle = .main) -> String { "\(HaloShared.namespace(bundle: bundle)).search" }

    /// Must run before the app has finished launching. `work` returns `true` when there is more to do; it is cancelled when the time is up.
    public static func register(_ work: @escaping @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier(), using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let box = Box(task: task)
            let running = Task {
                let more = await work()
                if more { schedule() }
                box.task.setTaskCompleted(success: !Task.isCancelled)
            }
            box.task.expirationHandler = {
                running.cancel()
                schedule()
            }
        }
    }

    public static func schedule(log: HaloLog? = nil) {
        let request = BGProcessingTaskRequest(identifier: identifier())
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do { try BGTaskScheduler.shared.submit(request) } catch { log?.info("search processing unavailable") }
    }

    public static func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier()) }
}
#endif

extension HaloShared {
    /// Where Halo's search indexes live: the app's private folder, which no extension can open (D124).
    public static func searchDirectory() -> URL { URL.applicationSupportDirectory.appendingPathComponent("search", isDirectory: true) }

    /// The index folder of one account, named by a hash (PERSISTENCE §1).
    public static func searchDirectory(for account: AccountID) -> URL { searchDirectory().appendingPathComponent(KeychainStore.directoryHash(account), isDirectory: true) }
}
