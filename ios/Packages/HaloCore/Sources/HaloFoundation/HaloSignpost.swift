import Synchronization
#if canImport(os)
import os
#endif

/// What Halo times (docs/architecture/LOGGING_AND_DIAGNOSTICS.md §5). The raw value is the signpost's name in Instruments and in
/// `XCTOSSignpostMetric`. Nothing but the name is ever recorded: no identifiers, sizes or content (SECURITY §6).
public enum SignpostInterval: String, Sendable, CaseIterable {
    /// Process start-up (first line of `HaloApp.init`) → the room list has rows. Not recorded for background launches or signed-out starts.
    case coldStart = "cold-start"
    /// A room was chosen (its chat-list row tapped, or put on the navigation path) → its rows are visible at the newest message.
    case roomOpen = "room-open"
    /// The same start → the first frame that draws the room's rows (M19-9): the message area is no longer empty.
    case roomFirstRows = "room-first-rows"
    /// One immediate `/sync` (no long poll): request, response processing and store writes in the SDK.
    case syncCatchUp = "sync-catch-up"
    /// One long-poll `/sync`; includes the server's waiting time, so only its processing tail says anything about speed.
    case syncLongPoll = "sync-long-poll"
    /// Decoding one image (or the frames of one animation) for display.
    case imageDecode = "image-decode"
    /// One push in the notification extension, from its start to the delivered notification.
    case notificationService = "notification-service"
    /// One turn of the main run loop that took 250 ms or more (`MainThreadHangs`, performance suite only).
    case mainThreadHang = "main-thread-hang"
}

/// Performance signposts (GA-02): they cost next to nothing when nobody records, so they stay in Release builds, where the budgets are measured.
public enum HaloSignpost {
    /// Fixed, not the bundle identifier: Debug, Beta, Release and the extensions are read the same way.
    public static let subsystem = "one.mbm.halo"
    public static let category = "performance"

    /// An interval that has begun. Dropping it without `end()` records nothing.
    public final class Running: Sendable {
        private let finish: Mutex<(@Sendable () -> Void)?>

        init(_ finish: @escaping @Sendable () -> Void) { self.finish = Mutex(finish) }

        /// Records the interval; only the first call counts.
        public func end() {
            let finish = finish.withLock { current -> (@Sendable () -> Void)? in
                defer { current = nil }
                return current
            }
            finish?()
        }
    }

    public static func begin(_ interval: SignpostInterval) -> Running {
        #if canImport(os)
        let name = interval.signpostName
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        return Running { signposter.endInterval(name, state) }
        #else
        return Running {}
        #endif
    }

    public static func measure<T, E: Error>(_ interval: SignpostInterval, _ work: () throws(E) -> T) throws(E) -> T {
        let running = begin(interval)
        defer { running.end() }
        return try work()
    }

    #if canImport(os)
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    #endif
}

#if canImport(os)
extension SignpostInterval {
    /// `OSSignposter` needs a literal; `HaloSignpostTests` checks that it equals the raw value.
    var signpostName: StaticString {
        switch self {
        case .coldStart: "cold-start"
        case .roomOpen: "room-open"
        case .roomFirstRows: "room-first-rows"
        case .syncCatchUp: "sync-catch-up"
        case .syncLongPoll: "sync-long-poll"
        case .imageDecode: "image-decode"
        case .notificationService: "notification-service"
        case .mainThreadHang: "main-thread-hang"
        }
    }
}
#endif
