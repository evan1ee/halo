import Foundation
import Observation

/// Settings → Bots: the list on screen and its edits. An edit is synced as the difference to the list the account had last
/// confirmed, so it can't overwrite entries this device hasn't loaded; a failed one goes along with the next edit. Edits are
/// sent one after the other.
@MainActor
@Observable
final class BotListEditor {
    /// Applies `old` → `new` to the account's list; returns the list the account then has, or `nil` when that failed.
    typealias Sync = @Sendable (_ old: [String], _ new: [String]) async -> [String]?

    private(set) var senders: [String]
    private(set) var syncFailed = false

    @ObservationIgnored private var confirmed: [String]
    @ObservationIgnored private var sending: Task<Void, Never>?
    private let store: ([String]) -> Void
    private let sync: Sync?

    init(senders: [String], store: @escaping ([String]) -> Void, sync: Sync?) {
        self.senders = senders
        self.confirmed = senders
        self.store = store
        self.sync = sync
    }

    func add(_ sender: String) {
        guard !senders.contains(sender) else { return }
        change(senders + [sender])
    }

    func remove(atOffsets offsets: IndexSet) {
        change(senders.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
    }

    /// Waits for the edits made so far.
    func settled() async { await sending?.value }

    private func change(_ list: [String]) {
        senders = list
        store(list)
        guard let sync else { return }
        let previous = sending
        sending = Task {
            await previous?.value
            guard let merged = await sync(confirmed, list) else { syncFailed = true; return }
            syncFailed = false
            confirmed = list
            guard senders == list else { return }  // a later edit is based on `list`; it merges again
            senders = merged
            confirmed = merged
            store(merged)
        }
    }
}
