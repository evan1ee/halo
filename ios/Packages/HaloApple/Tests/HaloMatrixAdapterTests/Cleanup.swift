import Foundation
import HaloFoundation
import Synchronization

/// What a test must undo on the shared dev account (rooms, devices), run before the test returns, whether it passed or threw.
/// Not `defer { Task { … } }`: nothing awaits that task, so the process can end first and the rooms stay behind.
final class Cleanup: Sendable {
    private let steps = Mutex<[@Sendable () async -> Void]>([])

    /// Adds a step; the steps run last added first (a room is left before its device signs out).
    func add(_ step: @escaping @Sendable () async -> Void) { steps.withLock { $0.append(step) } }

    fileprivate func run() async {
        let pending = steps.withLock { all in
            defer { all = [] }
            return all
        }
        for step in pending.reversed() { await step() }
    }
}

func withCleanup(_ body: (Cleanup) async throws -> Void) async throws {
    let cleanup = Cleanup()
    do {
        try await body(cleanup)
    } catch {
        await cleanup.run()
        throw error
    }
    await cleanup.run()
}
