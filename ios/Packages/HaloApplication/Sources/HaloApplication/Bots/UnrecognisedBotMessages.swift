import Synchronization

/// Counts the messages of known bots whose formatted body matched no template, so they show as plain text (BOT_MESSAGES §8,
/// Settings → Diagnostics). Only distinct event IDs are counted, in memory; nothing about the messages is kept.
public final class UnrecognisedBotMessages: Sendable {
    private let seen = Mutex<Set<String>>([])

    public init() {}

    public func record(eventID: String) { seen.withLock { _ = $0.insert(eventID) } }

    public var count: Int { seen.withLock { $0.count } }
}
