import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

/// Seeded property tests P1, P2, P5, P5b, P6, P9, P10 of docs/testing/UNREAD_REGRESSION_TESTS.md §2. The seed is part of
/// every failure message.
@Suite("ReadStatePolicy properties")
struct ReadStatePropertyTests {
    private let room = try! RoomID("!r:x.org")
    private let cases = 10_000

    private func random(_ rng: inout SeededRandomNumberGenerator) -> RoomReadInputs {
        let mode = [NotificationMode.allMessages, .mentionsAndKeywords, .mute].randomElement(using: &rng)!
        let membership = [Membership.joined, .joined, .joined, .invited, .left].randomElement(using: &rng)!
        let latest: LatestEventRef? = Bool.random(using: &rng)
            ? LatestEventRef(timestamp: Date(timeIntervalSince1970: Double(Int.random(in: 0...200, using: &rng))), senderIsSelf: Bool.random(using: &rng))
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
            unconfirmedNotified: notified)
    }

    private func forAll(seed: UInt64 = 42, _ body: (RoomReadInputs, RoomReadState, String) -> Void) {
        var rng = SeededRandomNumberGenerator(seed: seed)
        for n in 0..<cases {
            let input = random(&rng)
            body(input, ReadStatePolicy.evaluate(input), "seed \(seed) case \(n)")
        }
    }

    @Test("P1: a covering intent with nothing newer notified leaves attention only for marked-unread rooms and invites")
    func p1() {
        forAll { input, state, label in
            guard input.membership == .joined, let intent = input.localIntent, let latest = input.latestEvent, latest.timestamp <= intent,
                input.unconfirmedNotified.isEmpty
            else { return }
            #expect(state.attention == input.counts.isMarkedUnread, Comment(rawValue: label))
        }
    }

    @Test("P2: no crash; no display exactly when nothing needs attention")
    func p2() {
        forAll { _, state, label in
            if state.attention { #expect(state.display != .none, Comment(rawValue: label)) } else { #expect(state.display == .none, Comment(rawValue: label)) }
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
                latestEvent: a.latestEvent, localIntent: a.localIntent, unconfirmedNotified: a.unconfirmedNotified)
            let ra = ReadStatePolicy.evaluate(a), rb = ReadStatePolicy.evaluate(b)
            #expect(ra.reasons.contains(.intentCovers) == rb.reasons.contains(.intentCovers), Comment(rawValue: "seed 7 case \(n)"))
        }
    }
}
