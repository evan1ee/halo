import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("ReadStatePolicy")
struct ReadStatePolicyTests {
    private let room = try! RoomID("!r:x.org")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func inputs(
        membership: Membership = .joined, encrypted: Bool = false, mode: NotificationMode = .allMessages,
        server: ServerCounts = .zero, sdk: SDKCounts = .zero, marked: Bool = false,
        latest: LatestEventRef? = nil, intent: Date? = nil, receipt: Date? = nil,
        intentEventID: EventID? = nil, intentConfirmed: Bool = false, ownReceiptEventID: EventID? = nil,
        notified: [NotifiedRef] = []
    ) -> RoomReadInputs {
        RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: encrypted,
            counts: RoomReadCounts(mode: mode, server: server, sdk: sdk, isMarkedUnread: marked),
            latestEvent: latest, localIntent: intent, receiptReadThrough: receipt,
            localIntentEventID: intentEventID, localIntentConfirmed: intentConfirmed, ownReceiptEventID: ownReceiptEventID,
            unconfirmedNotified: notified)
    }

    private func eval(_ i: RoomReadInputs) -> RoomReadState { ReadStatePolicy.evaluate(i) }

    @Test("E0: an invite needs attention; a room the user left or was banned from never does")
    func invites() {
        let invite = eval(inputs(membership: .invited))
        #expect(invite.attention && invite.display == .dot && invite.reasons == [.invite])
        for membership in [Membership.left, .banned, .knocked] {
            let state = eval(inputs(membership: membership, server: ServerCounts(notification: 5, highlight: 1)))
            #expect(!state.attention && state.display == .none)
        }
    }

    @Test("E1/E1b: a local read intent or an own latest message clears the counts")
    func intentAndOwn() {
        let latest = LatestEventRef(timestamp: t0, senderIsSelf: false)
        let counted = ServerCounts(notification: 3, highlight: 0)
        #expect(!eval(inputs(server: counted, latest: latest, intent: t0)).attention)
        #expect(eval(inputs(server: counted, latest: latest, intent: t0)).reasons == [.intentCovers])
        // An intent older than the latest event doesn't cover it.
        #expect(eval(inputs(server: counted, latest: latest, intent: t0 - 1)).attention)
        let own = LatestEventRef(timestamp: t0, senderIsSelf: true)
        #expect(eval(inputs(server: counted, latest: own)).reasons == [.ownLatest])
        // …unless a notified event is still unsynced.
        #expect(eval(inputs(server: counted, latest: own, notified: [NotifiedRef(timestamp: t0 + 1, isMention: false)])).attention)
    }

    @Test("R-07: once the SDK has applied the read position, its positive counts beat 'covers the latest event' (E1, E1b)")
    func sdkCountsAfterRead() {
        let latest = LatestEventRef(timestamp: t0, senderIsSelf: false)
        let utd = SDKCounts(unreadMessages: 1, unreadNotifications: 1, unreadMentions: 0)
        let server = ServerCounts(notification: 1, highlight: 0)
        // The receipt the SDK holds is the read position: a newer event it can't decrypt is unread, though the latest event leaves it out.
        let applied = eval(inputs(encrypted: true, server: server, sdk: utd, latest: latest, intent: t0, receipt: t0))
        #expect(applied.attention && applied.display == .count(1) && applied.reasons == [.sdkUnreadAfterRead, .sdkCounts])
        // Read on another device further than here: still applied.
        #expect(eval(inputs(encrypted: true, server: server, sdk: utd, latest: latest, intent: t0 + 5, receipt: t0 + 5)).attention)
        // The local read position is ahead of the SDK's receipt (sent or not, not echoed yet): the SDK's count is stale, E1 holds.
        let ahead = eval(inputs(encrypted: true, server: server, sdk: utd, latest: latest, intent: t0, receipt: t0 - 1))
        #expect(!ahead.attention && ahead.reasons == [.intentCovers])
        // The receipt is unknown: E1 holds as before.
        #expect(eval(inputs(encrypted: true, server: server, sdk: utd, latest: latest, intent: t0)).reasons == [.intentCovers])
        // No SDK count: E1 holds even with the receipt applied.
        #expect(eval(inputs(encrypted: true, server: server, latest: latest, intent: t0, receipt: t0)).reasons == [.intentCovers])
        // E1b: the own latest event is on the server, so the SDK took it as a receipt; what it still counts came after it.
        let own = LatestEventRef(timestamp: t0, senderIsSelf: true)
        let afterOwn = eval(inputs(encrypted: true, server: server, sdk: utd, latest: own))
        #expect(afterOwn.attention && afterOwn.reasons == [.sdkUnreadAfterRead, .sdkCounts])
        // A local echo (sending, or failed) isn't a receipt for the SDK yet: E1b holds.
        let echo = LatestEventRef(timestamp: t0, senderIsSelf: true, isLocal: true)
        #expect(eval(inputs(encrypted: true, server: server, sdk: utd, latest: echo)).reasons == [.ownLatest])
        // S13: an own message after unread the SDK already reset (implicit receipt): no SDK count, the server's are hidden.
        #expect(eval(inputs(server: ServerCounts(notification: 3, highlight: 0), latest: own)).reasons == [.ownLatest])
    }

    @Test("R-06 (ADR-0020): E1 orders by event identity when known and yields to server/SDK counts once the receipt is confirmed")
    func identityAndConfirmedIntent() throws {
        let e1 = try EventID("$e1"), e2 = try EventID("$e2")
        let counted = ServerCounts(notification: 1, highlight: 0)

        // Same timestamp, different event IDs: identity says e1 does NOT cover e2.
        let equalTs = eval(inputs(
            server: counted,
            latest: LatestEventRef(timestamp: t0, senderIsSelf: false, eventID: e2),
            intent: t0, intentEventID: e1))
        #expect(equalTs.attention && equalTs.display == .count(1) && equalTs.reasons == [.serverCounts])

        // Skewed earlier timestamp, different event IDs: identity says e1 does NOT cover e2.
        let skewed = eval(inputs(
            server: counted,
            latest: LatestEventRef(timestamp: t0 - 600, senderIsSelf: false, eventID: e2),
            intent: t0, intentEventID: e1))
        #expect(skewed.attention && skewed.display == .count(1) && skewed.reasons == [.serverCounts])

        // Matching event IDs, unconfirmed receipt: E1 clears optimistically even if timestamp were skewed.
        let matched = eval(inputs(
            server: counted,
            latest: LatestEventRef(timestamp: t0 + 600, senderIsSelf: false, eventID: e1),
            intent: t0, intentEventID: e1, intentConfirmed: false))
        #expect(!matched.attention && matched.reasons == [.intentCovers])

        // Latest event ID unknown (Room.latestEvent, F-FFI-15), receipt confirmed on server, yet server still counts:
        // stale intent yields immediately instead of hiding unread for 7 days (revisiting D72).
        let staleConfirmed = eval(inputs(
            server: counted,
            latest: LatestEventRef(timestamp: t0, senderIsSelf: false),
            intent: t0, intentEventID: e1, intentConfirmed: true))
        #expect(staleConfirmed.attention && staleConfirmed.display == .count(1) && staleConfirmed.reasons == [.intentStale, .serverCounts])

        // Unconfirmed (pending) intent with unknown latest event ID still clears optimistically.
        let pending = eval(inputs(
            server: counted,
            latest: LatestEventRef(timestamp: t0, senderIsSelf: false),
            intent: t0, intentEventID: e1, intentConfirmed: false))
        #expect(!pending.attention && pending.reasons == [.intentCovers])
    }

    @Test("E2: server zero wins over stale SDK counts in all-messages rooms")
    func serverZero() {
        let state = eval(inputs(sdk: SDKCounts(unreadMessages: 2, unreadNotifications: 2, unreadMentions: 0)))
        #expect(!state.attention && !state.hasUnread)
        #expect(state.reasons == [.serverZero, .sdkStale])
        // Encrypted all-messages rooms are still countable by the server.
        #expect(eval(inputs(encrypted: true, sdk: SDKCounts(unreadMessages: 1, unreadNotifications: 1, unreadMentions: 0))).reasons.contains(.serverZero))
    }

    @Test("E2 in a quiet unencrypted room keeps the quiet unread indicator from the SDK count")
    func quietUnread() {
        let state = eval(inputs(mode: .mentionsAndKeywords, sdk: SDKCounts(unreadMessages: 1, unreadNotifications: 0, unreadMentions: 0)))
        #expect(!state.attention && state.hasUnread && state.display == .none)
    }

    @Test("E3a: unencrypted rooms use the server counts, exactly")
    func unencrypted() {
        let state = eval(inputs(server: ServerCounts(notification: 4, highlight: 0)))
        #expect(state.attention && state.display == .count(4) && state.confidence == .exact && state.reasons == [.serverCounts])
        let mention = eval(inputs(server: ServerCounts(notification: 4, highlight: 2)))
        #expect(mention.display == .mentions(2))
    }

    @Test("E3b: encrypted rooms use the SDK counts; a larger server count makes them approximate")
    func encryptedSDK() {
        let sdk = SDKCounts(unreadMessages: 3, unreadNotifications: 2, unreadMentions: 0)
        let exact = eval(inputs(encrypted: true, server: ServerCounts(notification: 2, highlight: 0), sdk: sdk))
        #expect(exact.display == .count(2) && exact.confidence == .exact && exact.reasons == [.sdkCounts])
        let over = eval(inputs(encrypted: true, server: ServerCounts(notification: 7, highlight: 0), sdk: sdk))
        #expect(over.confidence == .approximate && over.display == .dot && over.reasons == [.sdkCounts, .encServerOvercount])
    }

    @Test("E3c: in an encrypted room a server count the SDK doesn't share (a poll vote, a call signal) is no unread (R-01)")
    func encryptedServerOnly() {
        let state = eval(inputs(encrypted: true, server: ServerCounts(notification: 5, highlight: 0)))
        #expect(!state.attention && !state.hasUnread && state.display == .none && state.confidence == .exact && state.reasons == [.encServerOnly])
        // A server highlight without an SDK count is treated the same: the server can't see mentions in ciphertext.
        #expect(!eval(inputs(encrypted: true, server: ServerCounts(notification: 1, highlight: 1))).attention)
        // Evidence the policy still adds on top: a pushed event, or the user's own unread flag.
        let pushed = eval(inputs(encrypted: true, server: ServerCounts(notification: 1, highlight: 0), notified: [NotifiedRef(timestamp: Date(timeIntervalSince1970: 50), isMention: false)]))
        #expect(pushed.attention && pushed.reasons == [.encServerOnly, .notifiedUnsynced])
        #expect(eval(inputs(encrypted: true, server: ServerCounts(notification: 1, highlight: 0), marked: true)).attention)
        // An event the SDK can't decrypt is counted by the SDK too, so it is unread (E3b), not E3c.
        let utd = eval(inputs(encrypted: true, server: ServerCounts(notification: 1, highlight: 0), sdk: SDKCounts(unreadMessages: 1, unreadNotifications: 1, unreadMentions: 0)))
        #expect(utd.attention && utd.display == .count(1) && utd.reasons == [.sdkCounts])
        // A call invite: the SDK's push rules notify for it, though it isn't a message. Unread, and the SDK's count is used.
        let call = eval(inputs(encrypted: true, server: ServerCounts(notification: 1, highlight: 0), sdk: SDKCounts(unreadMessages: 0, unreadNotifications: 1, unreadMentions: 0)))
        #expect(call.attention && call.hasUnread && call.display == .count(1) && call.reasons == [.sdkCounts])
    }

    @Test("E2x: an encrypted room in mentions mode has a blind server; SDK mentions are approximate")
    func serverBlind() {
        let sdk = SDKCounts(unreadMessages: 2, unreadNotifications: 0, unreadMentions: 1)
        let state = eval(inputs(encrypted: true, mode: .mentionsAndKeywords, sdk: sdk))
        #expect(state.reasons == [.serverBlind, .sdkCounts])
        #expect(state.attention && state.confidence == .approximate && state.display == .mentions(1))
        // No SDK counts and a blind server: nothing to show.
        #expect(!eval(inputs(encrypted: true, mode: .mentionsAndKeywords)).attention)
    }

    @Test("E4: events the extension fetched but sync hasn't delivered count, mentions included")
    func notified() {
        let state = eval(inputs(notified: [NotifiedRef(timestamp: t0, isMention: false), NotifiedRef(timestamp: t0, isMention: true)]))
        #expect(state.attention && state.display == .mentions(1) && state.reasons.contains(.notifiedUnsynced))
        let quiet = eval(inputs(mode: .mentionsAndKeywords, notified: [NotifiedRef(timestamp: t0, isMention: false)]))
        #expect(!quiet.attention && quiet.hasUnread)
    }

    @Test("R-02: partitionRecords covers records up to notifiedThroughTs, supersedes synced events, and keeps encrypted gap mentions (S22)")
    func partitionRecords() throws {
        let e1 = try EventID("$1"), e2 = try EventID("$2"), e3 = try EventID("$3")
        let r1 = NotificationRecord(roomID: room, eventID: e1, timestamp: t0, isMention: false)
        let r2 = NotificationRecord(roomID: room, eventID: e2, timestamp: t0 + 10, isMention: true)
        let r3 = NotificationRecord(roomID: room, eventID: e3, timestamp: t0 + 20, isMention: false)

        // Covered by serverZero + latestEvent even when localIntent is nil.
        let readByServerZero = inputs(latest: LatestEventRef(timestamp: t0 + 10, senderIsSelf: false))
        #expect(ReadStatePolicy.notifiedThrough(for: readByServerZero) == t0 + 10)
        let p1 = ReadStatePolicy.partitionRecords(for: readByServerZero, records: [r1, r2, r3])
        #expect(p1.superseded == [e1, e2])
        #expect(p1.unconfirmed == [NotifiedRef(timestamp: t0 + 20, isMention: false)])

        // Superseded by sync when latestEvent reached the record's timestamp (even while unread).
        let syncedUnread = inputs(
            encrypted: true, server: ServerCounts(notification: 1, highlight: 0),
            sdk: SDKCounts(unreadMessages: 1, unreadNotifications: 1, unreadMentions: 0),
            latest: LatestEventRef(timestamp: t0, senderIsSelf: false))
        let p2 = ReadStatePolicy.partitionRecords(for: syncedUnread, records: [r1])
        #expect(p2.superseded == [e1] && p2.unconfirmed.isEmpty)

        // S22: encrypted mentions-only room with a mention in a timeline gap (sdk.unreadMentions == 0) is NOT superseded by a newer latestEvent.
        let gapMention = inputs(
            encrypted: true, mode: .mentionsAndKeywords,
            sdk: SDKCounts(unreadMessages: 5, unreadNotifications: 0, unreadMentions: 0),
            latest: LatestEventRef(timestamp: t0 + 30, senderIsSelf: false))
        #expect(ReadStatePolicy.notifiedThrough(for: gapMention) == nil)
        let p3 = ReadStatePolicy.partitionRecords(for: gapMention, records: [r1, r2])
        #expect(p3.superseded == [e1])
        #expect(p3.unconfirmed == [NotifiedRef(timestamp: t0 + 10, isMention: true)])
    }

    @Test("E5 and modes: marked unread forces attention everywhere; mute and mentions modes suppress counts")
    func modesAndMarkedUnread() {
        let counted = ServerCounts(notification: 3, highlight: 0)
        #expect(!eval(inputs(mode: .mute, server: counted)).attention)
        #expect(!eval(inputs(mode: .mentionsAndKeywords, server: counted)).attention)
        #expect(eval(inputs(mode: .mentionsAndKeywords, server: ServerCounts(notification: 3, highlight: 1))).attention)
        for mode in [NotificationMode.allMessages, .mentionsAndKeywords, .mute] {
            let marked = eval(inputs(mode: mode, marked: true))
            #expect(marked.attention && marked.display == .dot && marked.reasons.contains(.markedUnread))
        }
    }

    @Test("D82: the badge is the total unread message count across rooms needing attention, recomputed from states")
    func badge() throws {
        func state(_ attention: Bool, count: Int) throws -> RoomReadState {
            RoomReadState(
                roomID: try RoomID("!\(UUID().uuidString.prefix(6)):x.org"),
                attention: attention, hasUnread: attention,
                display: attention ? (count > 0 ? .count(count) : .dot) : .none,
                confidence: .exact, badgeCount: attention ? max(count, 1) : 0, reasons: [])
        }
        #expect(BadgeCalculator.badge([]) == 0)
        #expect(BadgeCalculator.badge([try state(true, count: 10), try state(false, count: 0), try state(true, count: 3)]) == 13)
        // All-messages room with 10 unread messages including 1 mention contributes 10 (not 1).
        let mixed = eval(inputs(mode: .allMessages, server: ServerCounts(notification: 10, highlight: 1)))
        #expect(mixed.display == .mentions(1) && mixed.badgeCount == 10)
        // Mentions-only room with 5 messages and 2 mentions contributes 2; muted marked-unread contributes 1.
        let mentionsOnly = eval(inputs(mode: .mentionsAndKeywords, server: ServerCounts(notification: 5, highlight: 2)))
        let mutedMarked = eval(inputs(mode: .mute, marked: true))
        #expect(BadgeCalculator.badge([mixed, mentionsOnly, mutedMarked]) == 13)
    }

    @Test("evaluation is deterministic over a grid of inputs and never claims attention without a reason to")
    func totality() {
        for encrypted in [false, true] {
            for mode in [NotificationMode.allMessages, .mentionsAndKeywords, .mute] {
                for notify in [0, 1, 5] {
                    for highlight in [0, 1] {
                        for sdkMessages in [0, 2] {
                            let i = inputs(
                                encrypted: encrypted, mode: mode, server: ServerCounts(notification: notify, highlight: highlight),
                                sdk: SDKCounts(unreadMessages: sdkMessages, unreadNotifications: sdkMessages, unreadMentions: 0))
                            let a = eval(i), b = eval(i)
                            #expect(a == b)
                            if mode == .mute { #expect(!a.attention) }
                            if a.attention { #expect(a.display != .none) } else { #expect(a.display == .none) }
                            #expect(!a.reasons.isEmpty)
                        }
                    }
                }
            }
        }
    }

    @Test("E6: what was shown before the first sync is a floor per mode, never a ceiling, and zero once synced")
    func carriedUnsynced() throws {
        let room = try RoomID("!e6:x.org")
        func state(_ mode: NotificationMode, server: Int, carried: Int) -> RoomReadState {
            ReadStatePolicy.evaluate(RoomReadInputs(
                roomID: room, membership: .joined, isEncrypted: false,
                counts: RoomReadCounts(mode: mode, server: ServerCounts(notification: server, highlight: 0), sdk: .zero, isMarkedUnread: false),
                unsyncedCarried: carried))
        }
        let held = state(.allMessages, server: 3, carried: 8)
        #expect(held.badgeCount == 8 && held.display == .count(8) && held.reasons.contains(.carriedUnsynced))
        #expect(state(.allMessages, server: 0, carried: 8).badgeCount == 8)
        let higher = state(.allMessages, server: 9, carried: 8)
        #expect(higher.badgeCount == 9 && !higher.reasons.contains(.carriedUnsynced))
        #expect(state(.allMessages, server: 0, carried: 0).badgeCount == 0)
        #expect(state(.mentionsAndKeywords, server: 0, carried: 2).badgeCount == 2)
        #expect(state(.mute, server: 0, carried: 2).badgeCount == 0)  // muted meanwhile
    }
}
