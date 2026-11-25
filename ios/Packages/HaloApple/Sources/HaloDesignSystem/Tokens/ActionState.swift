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

/// Double-tap protection for actions that are many and keyed, such as "delete this message" or "mute that room" (AC-REL-4):
/// a second request for a key that is still running is ignored; a different key runs alongside it.
@MainActor
public final class ActionGuard {
    private var running: Set<String> = []

    public init() {}

    /// Whether `key` is running right now.
    public func isRunning(_ key: String) -> Bool { running.contains(key) }

    /// Runs `operation` unless `key` is already running; returns whether it ran. The key is free again when it ends, however it ends.
    @discardableResult
    public func run(_ key: String, _ operation: () async -> Void) async -> Bool {
        guard running.insert(key).inserted else { return false }
        defer { running.remove(key) }
        await operation()
        return true
    }
}
