import Foundation

/// Pure energy and wake-up policy for the sync loop, periodic background work, and app refresh (ROADMAP M19-7, NFR-14/15).
///
/// Keeps live chat responsive under normal conditions while cutting unnecessary HTTP polls, radio wake-ups, and
/// auxiliary work when Low Power Mode is on, the device is thermally stressed, or iOS reports no network path.
public enum SyncEnergyPolicy {
    /// Device conditions relevant to sync scheduling.
    public struct Conditions: Sendable, Equatable {
        public var lowPower: Bool
        /// Thermal state `.serious` or `.critical`.
        public var isHot: Bool
        /// The system reports no satisfied network path (e.g. airplane mode).
        public var offline: Bool

        public init(lowPower: Bool = false, isHot: Bool = false, offline: Bool = false) {
            self.lowPower = lowPower
            self.isHot = isHot
            self.offline = offline
        }
    }

    /// Scheduling parameters derived from `Conditions`.
    public struct Schedule: Sendable, Equatable {
        /// Server long-poll timeout (`timeoutMs`) for `/sync`. Must stay below the SDK request timeout (15 s, GA-29)
        /// so healthy long-polls never trip the half-open connection cutoff.
        public let longPollMilliseconds: UInt64
        /// Pause inserted after an *empty* long-poll response (no room changes) before starting the next `/sync`.
        /// Zero under normal conditions; positive under Low Power Mode or thermal stress. Active chats with incoming
        /// events never sleep here.
        public let idleRest: Duration
        /// Initial backoff after a transient network error.
        public let minimumBackoff: Duration
        /// Maximum backoff after repeated network errors or while offline.
        public let maximumBackoff: Duration
        /// Minimum interval for `BGAppRefreshTaskRequest`.
        public let backgroundRefreshInterval: TimeInterval
        /// Pause non-essential background work (speculative room-timeline warming, periodic read-state auditor).
        public let pauseAuxiliaryWork: Bool

        public init(
            longPollMilliseconds: UInt64,
            idleRest: Duration,
            minimumBackoff: Duration,
            maximumBackoff: Duration,
            backgroundRefreshInterval: TimeInterval,
            pauseAuxiliaryWork: Bool
        ) {
            self.longPollMilliseconds = longPollMilliseconds
            self.idleRest = idleRest
            self.minimumBackoff = minimumBackoff
            self.maximumBackoff = maximumBackoff
            self.backgroundRefreshInterval = backgroundRefreshInterval
            self.pauseAuxiliaryWork = pauseAuxiliaryWork
        }
    }

    /// SDK request timeout (15 s, GA-29). `longPollMilliseconds` stays strictly below this with headroom.
    public static let requestTimeoutMilliseconds: UInt64 = 15_000
    /// Standard long-poll duration (12 s, up from 8 s): 33 % fewer empty wake-ups while keeping 3 s headroom under the 15 s cutoff.
    public static let normalLongPollMilliseconds: UInt64 = 12_000

    public static func schedule(for conditions: Conditions) -> Schedule {
        if conditions.isHot {
            return Schedule(
                longPollMilliseconds: normalLongPollMilliseconds,
                idleRest: .seconds(25),
                minimumBackoff: .seconds(5),
                maximumBackoff: .seconds(120),
                backgroundRefreshInterval: 60 * 60,
                pauseAuxiliaryWork: true
            )
        }
        if conditions.lowPower {
            return Schedule(
                longPollMilliseconds: normalLongPollMilliseconds,
                idleRest: .seconds(15),
                minimumBackoff: .seconds(3),
                maximumBackoff: .seconds(120),
                backgroundRefreshInterval: 45 * 60,
                pauseAuxiliaryWork: true
            )
        }
        return Schedule(
            longPollMilliseconds: normalLongPollMilliseconds,
            idleRest: .zero,
            minimumBackoff: .seconds(1),
            maximumBackoff: .seconds(60),
            backgroundRefreshInterval: 15 * 60,
            pauseAuxiliaryWork: false
        )
    }

    /// Next exponential retry delay, clamped to `[schedule.minimumBackoff, schedule.maximumBackoff]`.
    public static func nextBackoff(current: Duration, schedule: Schedule) -> Duration {
        let clamped = max(current, schedule.minimumBackoff)
        return min(clamped * 2, schedule.maximumBackoff)
    }
}
