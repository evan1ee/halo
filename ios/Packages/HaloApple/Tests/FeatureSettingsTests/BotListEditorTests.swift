import Foundation
import Synchronization
import Testing
@testable import FeatureSettings

@MainActor
@Suite("Bot list editor (D120)")
struct BotListEditorTests {
    /// The account's list as another device could have left it.
    private final class Account: Sendable {
        struct State { var list: [String]; var online = true; var calls: [[[String]]] = [] }
        let state: Mutex<State>
        init(_ list: [String]) { state = Mutex(State(list: list)) }

        func sync(_ old: [String], _ new: [String]) -> [String]? {
            state.withLock { state in
                state.calls.append([old, new])
                guard state.online else { return nil }
                state.list = state.list.filter { !old.contains($0) || new.contains($0) } + new.filter { !old.contains($0) && !state.list.contains($0) }
                return state.list
            }
        }
    }

    private func editor(_ senders: [String], _ account: Account, store: @escaping ([String]) -> Void = { _ in }) -> BotListEditor {
        BotListEditor(senders: senders, store: store, sync: { old, new in account.sync(old, new) })
    }

    @Test("adding before the account's list is loaded keeps it and then shows it")
    func addBeforeLoad() async {
        let account = Account(["@kept:x.org"])
        var stored: [String] = []
        let editor = editor([], account) { stored = $0 }
        editor.add("@new:x.org")
        #expect(editor.senders == ["@new:x.org"] && stored == ["@new:x.org"])  // at once
        await editor.settled()
        #expect(account.state.withLock { $0.list } == ["@kept:x.org", "@new:x.org"])
        #expect(editor.senders == ["@kept:x.org", "@new:x.org"] && stored == editor.senders && !editor.syncFailed)
        // The entries it learnt can be removed, and only the removed one goes.
        editor.remove(atOffsets: [0])
        await editor.settled()
        #expect(account.state.withLock { $0.list } == ["@new:x.org"])
    }

    @Test("quick edits are sent in order and never drop what the editor didn't know")
    func quickEdits() async {
        let account = Account(["@kept:x.org"])
        let editor = editor([], account)
        editor.add("@a:x.org")
        editor.add("@b:x.org")
        editor.remove(atOffsets: [0])
        await editor.settled()
        #expect(account.state.withLock { $0.list } == ["@kept:x.org", "@b:x.org"])
        #expect(editor.senders == ["@kept:x.org", "@b:x.org"])
    }

    @Test("an edit that couldn't be synced stays on the device and goes along with the next one")
    func failedEdit() async {
        let account = Account(["@kept:x.org"])
        account.state.withLock { $0.online = false }
        let editor = editor(["@kept:x.org"], account)
        editor.add("@a:x.org")
        await editor.settled()
        #expect(editor.syncFailed && editor.senders == ["@kept:x.org", "@a:x.org"])
        account.state.withLock { $0.online = true }
        editor.add("@b:x.org")
        await editor.settled()
        #expect(!editor.syncFailed && account.state.withLock { $0.list } == ["@kept:x.org", "@a:x.org", "@b:x.org"])
    }
}
