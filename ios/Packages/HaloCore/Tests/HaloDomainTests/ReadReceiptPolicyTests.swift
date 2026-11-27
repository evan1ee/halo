import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("ReadReceiptPolicy (TIMELINE FR-6, M20-9)")
struct ReadReceiptPolicyTests {
    @Test("Excludes signed-in user and message sender, matching Element Web")
    func excludesOwnUserAndSender() throws {
        let me = try UserID("@me:example.org")
        let alice = try UserID("@alice:example.org")
        let bob = try UserID("@bob:example.org")
        let carol = try UserID("@carol:example.org")

        let normalized = ReadReceiptPolicy.normalize(
            [
                ReadReceiptEntry(userID: me, timestamp: Date(timeIntervalSince1970: 300)),
                ReadReceiptEntry(userID: alice, timestamp: Date(timeIntervalSince1970: 250)),
                ReadReceiptEntry(userID: bob, timestamp: Date(timeIntervalSince1970: 200)),
                ReadReceiptEntry(userID: carol, timestamp: Date(timeIntervalSince1970: 100)),
            ],
            ownUserID: me,
            sender: alice
        )

        #expect(normalized.map(\.userID) == [bob, carol])
    }

    @Test("Orders newest receipt timestamp first, undated last, deterministic ID tie-breaker")
    func ordersNewestFirstAndDeduplicates() throws {
        let ann = try UserID("@ann:example.org")
        let bob = try UserID("@bob:example.org")
        let cy = try UserID("@cy:example.org")
        let di = try UserID("@di:example.org")

        let tEarly = Date(timeIntervalSince1970: 1_000)
        let tLate = Date(timeIntervalSince1970: 2_000)

        let normalized = ReadReceiptPolicy.normalize(
            [
                ReadReceiptEntry(userID: di, timestamp: nil),
                ReadReceiptEntry(userID: cy, timestamp: tEarly),
                ReadReceiptEntry(userID: bob, timestamp: tEarly),
                ReadReceiptEntry(userID: ann, timestamp: tEarly),
                ReadReceiptEntry(userID: ann, timestamp: tLate),
                ReadReceiptEntry(userID: di, timestamp: nil),
            ],
            ownUserID: nil,
            sender: nil
        )

        #expect(normalized == [
            ReadReceiptEntry(userID: ann, timestamp: tLate),
            ReadReceiptEntry(userID: bob, timestamp: tEarly),
            ReadReceiptEntry(userID: cy, timestamp: tEarly),
            ReadReceiptEntry(userID: di, timestamp: nil),
        ])
    }
}
