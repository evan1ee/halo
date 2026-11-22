import Foundation
import Observation

/// Guards async UI actions against double-taps and cancels in-flight work on teardown (TD-07).
///
/// Usage in a `@MainActor @Observable` view model:
/// ```swift
/// let action = ActionState()
/// action.run { await doWork() } // ignores concurrent taps while `isRunning == true`
/// ```
@MainActor @Observable
public final class ActionState {
    public private(set) var isRunning = false
    private var currentTask: Task<Void, Never>?

    public init() {}

    /// Runs `operation` if no action is already in flight; concurrent calls are ignored (prevents double-taps).
    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        currentTask = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.currentTask = nil
            }
            await operation()
        }
        return true
    }

    /// Cancels any in-flight task (e.g. when a sheet or view disappears).
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
    }
}
