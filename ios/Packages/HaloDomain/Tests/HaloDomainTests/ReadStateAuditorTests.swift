import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("ReadStateAuditor")
struct ReadStateAuditorTests {
    private let room = try! RoomID("!r:x.org")
    private func t(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n)) }

    private func input(
        mode: NotificationMode = .allMessages, server: ServerCounts = .zero, sdk: SDKCounts = .zero, marked: Bool = false, encrypted: Bool = false,
        latest: LatestEventRef? = nil, intent: Date? = nil, notified: [NotifiedRef] = [], membership: Membership = .joined
    ) -> RoomReadInputs {
        RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: encrypted,
            counts: RoomReadCounts(mode: mode, server: server, sdk: sdk, isMarkedUnread: marked), latestEvent: latest, localIntent: intent, unconfirmedNotified: notified)
    }
    private func audit(_ i: RoomReadInputs) -> [AuditFinding] { ReadStateAuditor.audit(i, state: ReadStatePolicy.evaluate(i)) }

    @Test("agreeing rooms have no findings")
    func agree() {
        #expect(audit(input()).isEmpty)
        #expect(audit(input(server: ServerCounts(notification: 3, highlight: 1), sdk: SDKCounts(unreadMessages: 3, unreadNotifications: 3, unreadMentions: 1))).isEmpty)
        #expect(audit(input(marked: true)).isEmpty)
        #expect(audit(input(membership: .invited)).isEmpty)
    }

    @Test("a local read intent covering the latest event while the server still counts is explained (INTENT_UNCONFIRMED)")
    func intentUnconfirmed() {
        let i = input(server: ServerCounts(notification: 2, highlight: 0), latest: LatestEventRef(timestamp: t(10), senderIsSelf: false), intent: t(10))
        #expect(audit(i) == [AuditFinding(kind: .explained, reason: "INTENT_UNCONFIRMED")])
    }

    @Test("SDK counts left over after the server reached zero are SDK_STALE_PENDING_RECEIPT")
    func sdkStale() {
        let i = input(sdk: SDKCounts(unreadMessages: 2, unreadNotifications: 2, unreadMentions: 0))
        #expect(audit(i) == [AuditFinding(kind: .explained, reason: "SDK_STALE_PENDING_RECEIPT")])
    }

    @Test("encrypted mentions-only rooms are SERVER_BLIND; an SDK count below the server's is ENC_SERVER_OVERCOUNT")
    func encrypted() {
        let blind = input(mode: .mentionsAndKeywords, encrypted: true)
        #expect(audit(blind) == [AuditFinding(kind: .explained, reason: "SERVER_BLIND")])
        let over = input(server: ServerCounts(notification: 5, highlight: 0), sdk: SDKCounts(unreadMessages: 2, unreadNotifications: 2, unreadMentions: 0), encrypted: true)
        #expect(audit(over).contains(AuditFinding(kind: .explained, reason: "ENC_SERVER_OVERCOUNT")))
        #expect(!audit(over).contains { $0.kind == .unexplained })
    }

    @Test("a policy output the inputs can't support is unexplained")
    func unexplained() {
        let i = input()
        let impossible = RoomReadState(roomID: room, attention: true, hasUnread: true, display: .dot, confidence: .exact, reasons: [])
        #expect(ReadStateAuditor.audit(i, state: impossible).contains(AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_ATTENTION_WITHOUT_INPUT")))
        let hidden = RoomReadState(roomID: room, attention: false, hasUnread: false, display: .none, confidence: .exact, reasons: [])
        let counted = input(server: ServerCounts(notification: 1, highlight: 0))
        #expect(ReadStateAuditor.audit(counted, state: hidden) == [AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_SERVER_UNREAD_HIDDEN")])
        let mutedAttention = RoomReadState(roomID: room, attention: true, hasUnread: true, display: .dot, confidence: .exact, reasons: [])
        #expect(ReadStateAuditor.audit(input(mode: .mute, sdk: SDKCounts(unreadMessages: 1, unreadNotifications: 0, unreadMentions: 0)), state: mutedAttention)
            .contains(AuditFinding(kind: .unexplained, reason: "UNEXPLAINED_MUTED_ATTENTION")))
    }

    @Test("the stored inputs are counts and flags only")
    func inputsJSON() {
        let json = AuditEvent.inputsJSON(for: input(server: ServerCounts(notification: 2, highlight: 1), encrypted: true))
        #expect(json.contains("\"server\":[2,1]") && json.contains("\"enc\":true") && !json.contains("!r:x.org"))
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
    }

    @Test("over the whole input space the policy's own output never produces an unexplained finding")
    func policyIsSelfConsistent() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        for _ in 0..<10_000 {
            let mode = [NotificationMode.allMessages, .mentionsAndKeywords, .mute].randomElement(using: &rng)!
            let server = ServerCounts(notification: Int.random(in: 0...3, using: &rng), highlight: Int.random(in: 0...1, using: &rng))
            let sdk = SDKCounts(unreadMessages: Int.random(in: 0...3, using: &rng), unreadNotifications: Int.random(in: 0...3, using: &rng), unreadMentions: Int.random(in: 0...1, using: &rng))
            let latest = Bool.random(using: &rng) ? LatestEventRef(timestamp: t(Int.random(in: 0...20, using: &rng)), senderIsSelf: Bool.random(using: &rng)) : nil
            let i = input(mode: mode, server: server, sdk: sdk, marked: Bool.random(using: &rng), encrypted: Bool.random(using: &rng), latest: latest,
                          intent: Bool.random(using: &rng) ? t(Int.random(in: 0...20, using: &rng)) : nil)
            let unexplained = audit(i).filter { $0.kind == .unexplained }
            #expect(unexplained.isEmpty, "\(i) → \(unexplained)")
            if !unexplained.isEmpty { return }
        }
    }
}
