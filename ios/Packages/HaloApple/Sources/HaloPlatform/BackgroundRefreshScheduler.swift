import BackgroundTasks
import Foundation
import HaloFoundation

/// Asks iOS to wake the app for a short sync now and then (BACKGROUND_EXECUTION): the fallback that keeps the badge and the
/// widgets moving when a push is dropped or the gateway is down. iOS decides when, if at all.
public enum BackgroundRefreshScheduler {
    public static let interval: TimeInterval = 15 * 60

    public static func identifier(bundle: Bundle = .main) -> String { "\(HaloShared.namespace(bundle: bundle)).refresh" }

    /// Replaces any earlier request. Fails where app refresh is unavailable (the simulator, or switched off in Settings).
    public static func schedule(log: HaloLog? = nil, interval: TimeInterval = BackgroundRefreshScheduler.interval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier())
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do { try BGTaskScheduler.shared.submit(request) } catch { log?.info("background refresh unavailable") }
    }
}
