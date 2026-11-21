import HaloFoundation

/// Where the derived bot task index is kept (docs/features/BOT_ACTIVITY.md, `bot_task`). Implemented by `HaloPersistence`; faked
/// in `HaloTestSupport`. It is an index of what Halo has seen, never the truth about the bot's tasks.
public protocol BotTaskPort: Sendable {
    /// Stores `entries`, each replacing the stored one with the same key unless that one is newer (`asOf`). An entry without a
    /// source event keeps the stored one's. Idempotent.
    func upsert(_ entries: [BotTaskEntry]) async throws(HaloError)

    /// All entries of the signed-in account, newest `asOf` first.
    func entries() async throws(HaloError) -> [BotTaskEntry]

    /// Empties the index ("Rebuild index"): it is filled again as timelines are opened.
    func removeAll() async throws(HaloError)
}
