#if canImport(UIKit)
import Foundation
import Testing
@testable import HaloPlatform

@Suite("MainThreadHangs", .serialized)
@MainActor
struct MainThreadHangsTests {
    /// Runs the main run loop until `done`, at most two seconds.
    private func spin(until done: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !done(), Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    @Test("A blocked turn is a hang, a short one isn't")
    func hang() async {
        var hangs: [Duration] = []
        let observer = MainThreadHangs.start(runLoop: CFRunLoopGetMain()) { hangs.append($0) }
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        var fired = 0
        let short = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: false) { _ in MainActor.assumeIsolated { usleep(20_000); fired += 1 } }
        spin { fired == 1 }
        #expect(hangs.isEmpty)
        let long = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: false) { _ in MainActor.assumeIsolated { usleep(400_000); fired += 1 } }
        spin { !hangs.isEmpty }
        #expect(hangs.count == 1)
        #expect((hangs.first ?? .zero) >= .milliseconds(380))
        short.invalidate()
        long.invalidate()
    }
}
#endif
