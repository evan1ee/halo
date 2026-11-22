import Foundation
import HaloDomain
import Synchronization

/// An in-memory `ChatShortcutPort` that counts calls.
public final class FakeChatShortcutPort: ChatShortcutPort {
    private struct State {
        var stored: [ChatShortcut] = []
        var replaceCalls = 0
        var clearCalls = 0
    }

    private let state = Mutex(State())
    public init() {}

    public var replaceCalls: Int { state.withLock { $0.replaceCalls } }
    public var clearCalls: Int { state.withLock { $0.clearCalls } }

    public func load() -> [ChatShortcut] { state.withLock { $0.stored } }

    public func replace(with shortcuts: [ChatShortcut]) async {
        state.withLock {
            $0.stored = shortcuts
            $0.replaceCalls += 1
        }
    }

    public func clear() async {
        state.withLock {
            $0.stored = []
            $0.clearCalls += 1
        }
    }
}
