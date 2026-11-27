import Foundation
import HaloFoundation

/// A single user's read receipt on a timeline event, with the optional server timestamp of when they read it (TIMELINE FR-6, M20-9).
public struct ReadReceiptEntry: Sendable, Equatable, Hashable {
    public let userID: UserID
    public let timestamp: Date?

    public init(userID: UserID, timestamp: Date? = nil) {
        self.userID = userID
        self.timestamp = timestamp
    }
}

/// Normalises read receipts for display under a message, matching Element Web's reader set and ordering (TIMELINE FR-6, M20-9):
/// - Never shows the signed-in user as a reader.
/// - Never shows the message's own sender as a reader of their own message.
/// - Deduplicates by user ID, keeping the newest timestamp when multiple receipts exist.
/// - Orders most-recent reader first (descending timestamp), with undated receipts after dated ones and
///   deterministic user-ID tie-breaking.
public enum ReadReceiptPolicy {
    public static func normalize(
        _ entries: [ReadReceiptEntry],
        ownUserID: UserID?,
        sender: UserID?
    ) -> [ReadReceiptEntry] {
        var latestByUser: [UserID: Date?] = [:]
        for entry in entries {
            if let ownUserID, entry.userID == ownUserID { continue }
            if let sender, entry.userID == sender { continue }
            if let existing = latestByUser[entry.userID] {
                switch (existing, entry.timestamp) {
                case (let a?, let b?):
                    if b > a { latestByUser[entry.userID] = b }
                case (nil, let b?):
                    latestByUser[entry.userID] = b
                default:
                    break
                }
            } else {
                latestByUser[entry.userID] = entry.timestamp
            }
        }
        return latestByUser
            .map { ReadReceiptEntry(userID: $0.key, timestamp: $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.timestamp, rhs.timestamp) {
                case (let a?, let b?) where a != b: return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.userID.rawValue < rhs.userID.rawValue
                }
            }
    }
}
