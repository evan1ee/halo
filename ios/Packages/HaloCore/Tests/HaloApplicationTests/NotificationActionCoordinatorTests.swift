import Foundation
import HaloDomain
import HaloFoundation
import Synchronization
import Testing
@testable import HaloApplication

@Suite("NotificationActionCoordinator (M18-7, AC-REL-7)")
struct NotificationActionCoordinatorTests {
    private final class Recorder: Sendable {
        let sent = Mutex<[String]>([])
        let read = Mutex<[RoomID]>([])
        let drafts = Mutex<[String]>([])
        let sendResult = Mutex<Result<SiriSendOutcome, HaloError>>(.success(.confirmed))
        let readResult = Mutex<HaloError?>(nil)
    }

    private func make(_ recorder: Recorder) -> NotificationActionCoordinator {
        NotificationActionCoordinator(
            send: { text, _ throws(HaloError) in
                recorder.sent.withLock { $0.append(text) }
                return try recorder.sendResult.withLock { $0 }.get()
            },
            markRead: { room, _ throws(HaloError) in
                if let error = recorder.readResult.withLock({ $0 }) { throw error }
                recorder.read.withLock { $0.append(room) }
            },
            keepDraft: { text, _ in recorder.drafts.withLock { $0.append(text) } })
    }

    private let room = try! RoomID("!r:example.org")

    @Test("a reply is sent once, however often iOS hands over the same notification; a confirmed send is done, a queued one says queued")
    func replyOnce() async {
        let recorder = Recorder()
        let coordinator = make(recorder)
        #expect(await coordinator.reply(text: "  on my way ", to: room, notification: "n1") == .done)
        #expect(await coordinator.reply(text: "on my way", to: room, notification: "n1") == .duplicate)
        #expect(recorder.sent.withLock { $0 } == ["on my way"])
        recorder.sendResult.withLock { $0 = .success(.queued) }
        #expect(await coordinator.reply(text: "again", to: room, notification: "n2") == .queued)
        #expect(recorder.drafts.withLock { $0 }.isEmpty)
    }

    @Test("a reply that can't be sent says so and keeps the typed text as a draft, so nothing is lost")
    func replyFails() async {
        let recorder = Recorder()
        recorder.sendResult.withLock { $0 = .failure(.network(retryable: true)) }
        let coordinator = make(recorder)
        #expect(await coordinator.reply(text: "see you", to: room, notification: "n1") == .failed)
        #expect(recorder.drafts.withLock { $0 } == ["see you"])
    }

    @Test("an empty reply sends nothing")
    func emptyReply() async {
        let recorder = Recorder()
        #expect(await make(recorder).reply(text: "   ", to: room, notification: "n1") == .failed)
        #expect(recorder.sent.withLock { $0 }.isEmpty && recorder.drafts.withLock { $0 }.isEmpty)
    }

    @Test("mark as read reads the room once; a failure is reported, not swallowed")
    func markRead() async {
        let recorder = Recorder()
        let coordinator = make(recorder)
        #expect(await coordinator.markRead(room: room, at: Date(), notification: "n1") == .done)
        #expect(await coordinator.markRead(room: room, at: Date(), notification: "n1") == .duplicate)
        #expect(recorder.read.withLock { $0 } == [room])
        recorder.readResult.withLock { $0 = .network(retryable: true) }
        #expect(await coordinator.markRead(room: room, at: Date(), notification: "n2") == .failed)
        // Reply and Mark as read on the same notification are separate actions.
        recorder.readResult.withLock { $0 = nil }
        #expect(await coordinator.reply(text: "ok", to: room, notification: "n1") == .done)
    }
}
