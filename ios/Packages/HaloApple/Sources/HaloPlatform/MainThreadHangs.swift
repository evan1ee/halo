#if canImport(UIKit)
import Foundation
import HaloFoundation
import UIKit

/// Records a `main-thread-hang` signpost whenever one turn of the main run loop takes 250 ms or more (NFR-13). Only for the performance
/// suite: it runs when the app was launched with `-HaloMeasureHangs YES`, and costs two run-loop observers then.
@MainActor
public enum MainThreadHangs {
    public static let threshold: Duration = .milliseconds(250)

    public static func startIfAsked(_ defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: "HaloMeasureHangs") { start(runLoop: CFRunLoopGetMain()) }
    }

    /// Observes `runLoop` until the returned observer is removed.
    @discardableResult
    static func start(runLoop: CFRunLoop, onHang: @escaping @MainActor (Duration) -> Void = { _ in }) -> CFRunLoopObserver? {
        let clock = ContinuousClock()
        var began: (at: ContinuousClock.Instant, signpost: HaloSignpost.Running)?
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    // Begun every turn, ended only when the turn was too long: a begun interval that never ends records nothing.
                    began = (clock.now, HaloSignpost.begin(.mainThreadHang))
                } else if let turn = began {
                    began = nil
                    let took = clock.now - turn.at
                    if took >= threshold {
                        turn.signpost.end()
                        onHang(took)
                    }
                }
            }
        }
        CFRunLoopAddObserver(runLoop, observer, .commonModes)
        return observer
    }
}
#endif
