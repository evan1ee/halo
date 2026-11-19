import Synchronization
import Testing
@testable import HaloFoundation

private final class CapturingSink: LogSink {
    struct Line: Equatable { let level: LogLevel; let category: LogCategory; let event: String; let code: String?; let id: String? }
    let lines = Mutex<[Line]>([])
    func emit(level: LogLevel, category: LogCategory, event: String, code: String?, id: String?) {
        lines.withLock { $0.append(Line(level: level, category: category, event: event, code: code, id: id)) }
    }
}

@Suite("HaloLog")
struct HaloLogTests {
    @Test("identifiers are logged as a salted short hash, never raw")
    func hashedIDs() throws {
        let sink = CapturingSink()
        let log = HaloLog(category: .session, sink: sink, salt: 7)
        let room = try RoomID("!secretroom:example.org")
        log.info("room opened", id: room)
        let line = try #require(sink.lines.withLock { $0.first })
        #expect(line.id == log.id(room))
        #expect(line.id?.hasPrefix("!") == true && line.id?.count == 7)
        #expect(!(line.id ?? "").contains("secret"))
    }

    @Test("the same identifier hashes differently under a different install salt")
    func salted() throws {
        let room = try RoomID("!a:example.org")
        let a = HaloLog(category: .db, sink: CapturingSink(), salt: 1).id(room)
        let b = HaloLog(category: .db, sink: CapturingSink(), salt: 2).id(room)
        #expect(a != b)
    }

    @Test("errors are logged by stable code, and levels below the minimum are dropped")
    func levels() {
        let sink = CapturingSink()
        let log = HaloLog(category: .sync, sink: sink, minimum: .warning, salt: 0)
        log.info("ignored")
        log.error("sync failed", error: .network(retryable: true))
        #expect(sink.lines.withLock { $0 } == [
            .init(level: .error, category: .sync, event: "sync failed", code: "NET_RETRYABLE", id: nil)
        ])
    }
}
