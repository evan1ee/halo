import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

/// Seeded property tests P1–P6, P9–P11 of docs/testing/UNREAD_REGRESSION_TESTS.md §2. The seed is part of
/// every failure message.
@Suite("ReadStatePolicy properties")
struct ReadStatePropertyTests {
    private let room = try! RoomID("!r:x.org")
    private let cases = 10_000

    private func random(_ rng: inout SeededRandomNumberGenerator) -> RoomReadInputs {
        let mode = [NotificationMode.allMessages, .mentionsAndKeywords, .mute].randomElement(using: &rng)!
        let membership = [Membership.joined, .joined, .joined, .invited, .left].randomElement(using: &rng)!
        let latest: LatestEventRef? = Bool.random(using: &rng)
            ? LatestEventRef(
                timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng))), senderIsSelf: Bool.random(using: &rng),
                isLocal: Bool.random(using: &rng))
            : nil
        let notified = (0..<Int.random(in: 0...2, using: &rng)).map { _ in
            NotifiedRef(timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng))), isMention: Bool.random(using: &rng))
        }
        return RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: Bool.random(using: &rng),
            counts: RoomReadCounts(
                mode: mode,
                server: ServerCounts(notification: Int.random(in: 0...3, using: &rng), highlight: Int.random(in: 0...2, using: &rng)),
                sdk: SDKCounts(
                    unreadMessages: Int.random(in: 0...3, using: &rng), unreadNotifications: Int.random(in: 0...3, using: &rng),
                    unreadMentions: Int.random(in: 0...2, using: &rng)),
                isMarkedUnread: Bool.random(using: &rng) && Bool.random(using: &rng)),
            latestEvent: latest,
            localIntent: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng))) : nil,
            receiptReadThrough: Bool.random(using: &rng) ? Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng))) : nil,
            unconfirmedNotified: notified)
    }

    private func forAll(seed: UInt64 = 42, _ body: (RoomReadInputs, RoomReadState, String) -> Void) {
        var rng = SeededRandomNumberGenerator(seed: seed)
        for n in 0..<cases {
            let input = random(&rng)
            body(input, ReadStatePolicy.evaluate(input), "seed \(seed) case \(n)")
        }
    }

    /// The SDK has applied the user's read position and still counts something (R-07): its receipt is at least the local
    /// position, or the own latest event is on the server (the SDK takes it as a receipt) and no unsent local position is past it.
    private func sdkCountsAfterRead(_ input: RoomReadInputs) -> Bool {
        guard input.counts.sdk != .zero else { return false }
        if let intent = input.localIntent, let receipt = input.receiptReadThrough, let latest = input.latestEvent, latest.timestamp <= intent,
           intent <= receipt { return true }
        guard let own = input.latestEvent, own.senderIsSelf, !own.isLocal, input.unconfirmedNotified.isEmpty else { return false }
        // An unconfirmed local position past the own event and the SDK's receipt: the SDK hasn't applied it (D119).
        guard let intent = input.localIntent, !input.localIntentConfirmed else { return true }
        return intent <= own.timestamp || input.receiptReadThrough.map { intent <= $0 } == true
    }

    @Test("P1: a covering intent with nothing newer notified leaves attention only for marked-unread rooms and invites (unless P11)")
    func p1() {
        forAll { input, state, label in
            guard input.membership == .joined, let intent = input.localIntent, let latest = input.latestEvent, latest.timestamp <= intent,
                input.unconfirmedNotified.isEmpty, !sdkCountsAfterRead(input)
            else { return }
            #expect(state.attention == input.counts.isMarkedUnread, Comment(rawValue: label))
        }
    }

    @Test("P11: when the SDK has applied the read position and counts a notification, an all-messages room the server can't clear has attention (R-07)")
    func p11() {
        forAll { input, state, label in
            let serverCanCount = !input.isEncrypted || input.counts.mode == .allMessages
            guard input.membership == .joined, input.counts.mode == .allMessages, input.counts.sdk.unreadNotifications > 0,
                sdkCountsAfterRead(input), !(input.counts.server == .zero && serverCanCount)
            else { return }
            #expect(state.attention, Comment(rawValue: label))
        }
    }

    @Test("P2: no crash; no display exactly when nothing needs attention")
    func p2() {
        forAll { _, state, label in
            if state.attention { #expect(state.display != .none, Comment(rawValue: label)) } else { #expect(state.display == .none, Comment(rawValue: label)) }
        }
    }

    private func withNotified(_ a: RoomReadInputs, _ notified: [NotifiedRef]) -> RoomReadInputs {
        RoomReadInputs(
            roomID: a.roomID, membership: a.membership, isEncrypted: a.isEncrypted, counts: a.counts, latestEvent: a.latestEvent,
            localIntent: a.localIntent, receiptReadThrough: a.receiptReadThrough, unconfirmedNotified: notified)
    }

    @Test("P3: the order of the notified events never changes the result")
    func p3() {
        var rng = SeededRandomNumberGenerator(seed: 3)
        for n in 0..<cases {
            let a = random(&rng)
            let shuffled = withNotified(a, a.unconfirmedNotified.shuffled(using: &rng))
            #expect(ReadStatePolicy.evaluate(a) == ReadStatePolicy.evaluate(shuffled), Comment(rawValue: "seed 3 case \(n)"))
        }
    }

    @Test("P4: re-evaluating gives the same state; repeating a notified event never changes attention (only the count)")
    func p4() {
        var rng = SeededRandomNumberGenerator(seed: 4)
        for n in 0..<cases {
            let a = random(&rng)
            let doubled = withNotified(a, a.unconfirmedNotified + a.unconfirmedNotified)
            let label = Comment(rawValue: "seed 4 case \(n)")
            #expect(ReadStatePolicy.evaluate(a) == ReadStatePolicy.evaluate(a), label)
            // NotifiedRef has no event id: the store (keyed by event) deduplicates, so the policy only guarantees attention.
            #expect(ReadStatePolicy.evaluate(a).attention == ReadStatePolicy.evaluate(doubled).attention, label)
        }
    }

    @Test("P5: server zero that can count, nothing notified, not marked, not invited: no attention")
    func p5() {
        forAll { input, state, label in
            let canCount = !input.isEncrypted || input.counts.mode == .allMessages
            guard input.membership == .joined, input.counts.server == .zero, canCount, input.unconfirmedNotified.isEmpty,
                !input.counts.isMarkedUnread
            else { return }
            #expect(!state.attention, Comment(rawValue: label))
        }
    }

    @Test("P5b: an encrypted room in mentions mode with SDK mentions and no covering intent has attention")
    func p5b() {
        forAll { input, state, label in
            let covered: Bool = { guard let i = input.localIntent, let l = input.latestEvent else { return false }; return l.timestamp <= i }()
            let ownLatest = input.latestEvent?.senderIsSelf == true && input.unconfirmedNotified.isEmpty
            guard input.membership == .joined, input.isEncrypted, input.counts.mode == .mentionsAndKeywords, input.counts.sdk.unreadMessages > 0,
                input.counts.sdk.unreadMentions > 0, !covered, !ownLatest
            else { return }
            #expect(state.attention, Comment(rawValue: label))
        }
    }

    @Test("P6: a notified event newer than every read position has attention (all messages, or a mention in mentions mode)")
    func p6() {
        forAll { input, state, label in
            guard input.membership == .joined else { return }
            let newest = input.unconfirmedNotified.map(\.timestamp).max()
            guard let newest else { return }
            // The policy takes unconfirmed events as given (the caller filters by position); they always count.
            let relevant = input.counts.mode == .allMessages ? true : input.unconfirmedNotified.contains { $0.isMention }
            if relevant && input.counts.mode != .mute { #expect(state.attention, Comment(rawValue: "\(label) newest \(newest)")) }
        }
    }

    @Test("P10: under E2 hasUnread follows the mode")
    func p10() {
        forAll { input, state, label in
            guard state.reasons.contains(.serverZero) else { return }
            if input.counts.mode == .allMessages {
                #expect(!state.hasUnread || state.reasons.contains(.notifiedUnsynced) || state.reasons.contains(.markedUnread), Comment(rawValue: label))
            } else {
                let expected = input.counts.sdk.unreadMessages > 0 || state.reasons.contains(.notifiedUnsynced) || state.reasons.contains(.markedUnread)
                #expect(state.hasUnread == expected, Comment(rawValue: label))
            }
        }
    }

    @Test("P9: changing only the server counts never changes what the local read position covers")
    func p9() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        for n in 0..<cases {
            let a = random(&rng)
            let b = RoomReadInputs(
                roomID: a.roomID, membership: a.membership, isEncrypted: a.isEncrypted,
                counts: RoomReadCounts(
                    mode: a.counts.mode, server: ServerCounts(notification: Int.random(in: 0...3, using: &rng), highlight: 0),
                    sdk: a.counts.sdk, isMarkedUnread: a.counts.isMarkedUnread),
                latestEvent: a.latestEvent, localIntent: a.localIntent, receiptReadThrough: a.receiptReadThrough, unconfirmedNotified: a.unconfirmedNotified)
            let ra = ReadStatePolicy.evaluate(a), rb = ReadStatePolicy.evaluate(b)
            #expect(ra.reasons.contains(.intentCovers) == rb.reasons.contains(.intentCovers), Comment(rawValue: "seed 7 case \(n)"))
        }
    }
}
