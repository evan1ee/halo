import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPersistence
import HaloTestSupport
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

private let env = ProcessInfo.processInfo.environment

/// Message search against a real server (INTEGRATION_TESTS S-SRCH-1…7), on a throwaway Synapse: `infra/test/run.sh search`.
@Suite("Message search", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh search"))
struct SearchContractTests {
    @Test("S-SRCH-1…3: an encrypted room is found live; its history from before sign-in after recovery, without opening the room", .timeLimit(.minutes(10)))
    func encrypted() async throws {
        try await ProxyControl().heal()
        let count = 400
        let (old, _, _) = try await signIn("old")
        try await old.startSync()
        let room = try await SearchServer(session: old).makeRoom(encrypted: true)
        try await SearchStage.wait(30, "the room") { (try? await old.room(room)) != nil }
        let timeline = try await (try await old.room(room)).timeline()
        for number in 0..<count { _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: "zebrafish \(number) 今天去AppleStore")) }
        let oldStage = try SearchStage(old)
        await old.stopSync()
        try await oldStage.start()
        // The sending device finds its own messages (they were in the timeline before search listened).
        try await SearchStage.wait(180, "the sender's own messages") { try await oldStage.bodies("zebrafish").count == count }
        #expect(try await oldStage.bodies("天去").count == count)
        let key = try await MatrixEncryptionPort(session: old).enableRecovery()
        try await old.encryption().waitForBackupUploadSteadyState(progressListener: nil)

        let (new, _, _) = try await signIn("new")
        let stage = try SearchStage(new)
        try await stage.start()
        try await stage.settle(120)
        #expect(try await stage.bodies("zebrafish").isEmpty)
        #expect(await stage.indexer.status.statistics.undecryptable >= count - 1)
        // Live, encrypted.
        _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: "fresh whisper"))
        try await SearchStage.wait(60, "the live message") { try await stage.bodies("whisper").count == 1 }
        // Recovery: nothing is opened.
        try await MatrixEncryptionPort(session: new).recover(recoveryKey: key)
        try await new.encryption().waitForE2eeInitializationTasks()
        await stage.indexer.keysArrived()
        try await SearchStage.wait(240, "the history after recovery") { try await stage.bodies("zebrafish").count == count }
        #expect(try await stage.bodies("zebrafish 7").contains { $0.hasPrefix("zebrafish 7 ") })
        #expect(try await stage.bodies("今天").count == count)
        // S-SRCH-7: no request carries the query (or any word of it).
        #expect(try await !proxyPaths().contains { $0.contains("zebrafish") || $0.contains("whisper") || $0.contains("/search") })
        // The app's own client still works on the shared store.
        let reply = try await (try await new.room(room)).timeline()
        _ = try await reply.send(msg: messageEventContentFromMarkdown(md: "from the new device"))
        try await SearchStage.wait(60, "the new device's message on the old one") { try await oldStage.bodies("new device").count == 1 }
        await stage.kill()
        await oldStage.kill()
    }

    @Test("an event nobody has the key for is counted, kept by ID and doesn't stop the rest", .timeLimit(.minutes(5)))
    func withoutKey() async throws {
        try await ProxyControl().heal()
        let (session, _, _) = try await signIn("opaque")
        let server = SearchServer(session: session)
        let room = try await server.makeRoom()
        let stage = try SearchStage(session)
        try await stage.start()
        try await stage.settle()
        let before = try await stage.store.statistics().undecryptable  // the account has another, encrypted room
        try await server.call("PUT", "rooms/\(room.rawValue)/send/m.room.encrypted/\(UUID().uuidString)", [
            "algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AwgAEnACgAkLmt6qF84IK", "session_id": "unknown", "sender_key": "x", "device_id": "y"])
        try await server.send("after it", to: room)
        try await SearchStage.wait(30, "both") {
            let statistics = try await stage.store.statistics()
            return try await stage.bodies("after").count == 1 && statistics.undecryptable == before + 1
        }
        await stage.kill()
    }

    @Test("S-SRCH-4: killed while reading history, it goes on from its last slice and finds the oldest message (AC-SRCH-4)", .timeLimit(.minutes(10)))
    func killAndResume() async throws {
        try await ProxyControl().heal()
        let (session, stored, directory) = try await signIn("resume")
        let server = SearchServer(session: session)
        let room = try await server.makeRoom()
        let first = try await server.send("the very oldest", to: room)
        for number in 0..<1_300 { try await server.send("line \(number)", to: room) }
        var stage = try SearchStage(session, slow: true)
        let index = stage.directory
        try await stage.start()
        try await SearchStage.wait(60, "a first slice") { try await stage.store.coverage()[room] != nil }
        await stage.kill()
        let before = try await stage.store.statistics().messages
        #expect(before >= 400 && before < 1_300)
        await stage.store.suspend(rooms: [])

        let again = MatrixSessionPort(baseDirectory: directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        stage = try SearchStage(again, directory: index)
        try await stage.start()
        try await stage.settle(120)
        #expect(try await stage.hits("oldest").map(\.eventID) == [first])
        #expect(try await stage.store.statistics().messages >= 1_301)

        // Opening the hit: around a message 1,300 messages back, then towards the newest (M20-1).
        let timelines = MatrixTimelinePort(session: again)
        let start = ContinuousClock.now
        let focused = try await timelines.openFocused(room: room, event: first)
        var items: [HaloDomain.TimelineItem] = []
        func ids() -> [EventID] { items.compactMap { if case .event(let event) = $0.content { event.eventID } else { nil } } }
        for await diff in focused.items() {
            try ListReducer.apply(diff, to: &items)
            if ids().contains(first) { break }
        }
        let took = ContinuousClock.now - start
        print("SEARCH open a message 1,300 back: \(took)")
        #expect(took < .seconds(2))
        let end = try await focused.paginateForwards(count: 50)
        #expect(!end)
        await focused.close()
        await #expect(throws: HaloError.notFound) { _ = try await timelines.openFocused(room: room, event: try EventID("$nothingHere")) }
        await stage.kill()
    }

    @Test("messages missed while away are read from the server, more than one page of them, also under reactions (AC-SRCH-1)", .timeLimit(.minutes(5)))
    func gap() async throws {
        try await ProxyControl().heal()
        let (session, stored, directory) = try await signIn("gap")
        let server = SearchServer(session: session)
        let room = try await server.makeRoom(), quiet = try await server.makeRoom()
        try await server.send("before", to: room)
        var stage = try SearchStage(session)
        let index = stage.directory
        try await stage.start()
        try await stage.settle()
        await stage.kill()
        await stage.store.suspend(rooms: [])
        var last: EventID?
        for number in 0..<150 { last = try await server.send("missed \(number)", to: room) }
        // Twelve reactions on top: the sync response shows no message at all.
        for number in 0..<12 {
            try await server.call("PUT", "rooms/\(room.rawValue)/send/m.reaction/\(UUID().uuidString)", [
                "m.relates_to": ["rel_type": "m.annotation", "event_id": last?.rawValue ?? "", "key": "k\(number)"]])
        }
        for number in 0..<3 { try await server.send("quiet \(number)", to: quiet) }

        let again = MatrixSessionPort(baseDirectory: directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        stage = try SearchStage(again, directory: index)
        try await stage.start()
        try await SearchStage.wait(90, "the missed messages") {
            let missed = try await stage.bodies("missed").count, quiet = try await stage.bodies("quiet").count
            return missed == 150 && quiet == 3
        }
        try await stage.settle()
        await stage.kill()
    }

    @Test("S-SRCH-5: edits and deletions, live and while not listening; polls, files, threads, a left room (AC-SRCH-6)", .timeLimit(.minutes(5)))
    func changes() async throws {
        try await ProxyControl().heal()
        let (session, stored, directory) = try await signIn("changes")
        let server = SearchServer(session: session)
        let room = try await server.makeRoom(), left = try await server.makeRoom()
        var stage = try SearchStage(session)
        let index = stage.directory
        try await stage.start()
        try await stage.settle()
        let edited = try await server.send("original wording", to: room), deleted = try await server.send("regretted words", to: room)
        let later = try await server.send("edited later", to: room), gone = try await server.send("deleted later", to: room)
        let thread = try await server.send("threaded answer", to: room, extra: ["m.relates_to": ["rel_type": "m.thread", "event_id": edited.rawValue]])
        try await server.send("IMG.jpg", to: room, extra: ["msgtype": "m.image", "body": "our boat", "filename": "IMG_77.jpg", "url": "mxc://x/y"])
        try await server.call("PUT", "rooms/\(room.rawValue)/send/org.matrix.msc3381.poll.start/\(UUID().uuidString)", [
            "org.matrix.msc1767.text": "Lunch?",
            "org.matrix.msc3381.poll.start": ["kind": "org.matrix.msc3381.poll.disclosed", "max_selections": 1, "question": ["org.matrix.msc1767.text": "Lunch?"],
                                              "answers": [["id": "1", "org.matrix.msc1767.text": "Pizza"], ["id": "2", "org.matrix.msc1767.text": "Soup"]]]])
        try await server.send("room to leave", to: left)
        try await SearchStage.wait(30, "the messages") {
            let later = try await stage.bodies("later").count, leave = try await stage.bodies("leave").count, image = try await stage.bodies("IMG_77").count
            return later == 2 && leave == 1 && image == 1
        }
        #expect(try await stage.hits("threaded").first?.threadRoot == edited && thread.rawValue.hasPrefix("$"))
        try await SearchStage.wait(30, "the poll") { try await stage.bodies("pizza") == ["Lunch?"] }
        // Regression: opening the thread of a hit, and exporting a room, failed with a generic SDK error (a timeline configured to report
        // undecryptable messages needs a hook Halo doesn't set).
        let opened = try await MatrixTimelinePort(session: session).openThread(room: room, rootEvent: edited)
        var items: [HaloDomain.TimelineItem] = []
        for await diff in opened.items() {
            try ListReducer.apply(diff, to: &items)
            if items.contains(where: { if case .event(let event) = $0.content { event.eventID == thread } else { false } }) { break }
        }
        await opened.close()
        #expect(try await MatrixRoomPort(session: session).exportMessages(in: room, limit: 50).contains { $0.eventID == edited.rawValue })
        try await server.edit(edited, to: "changed wording", in: room)
        try await server.delete(deleted, in: room)
        try await server.call("POST", "rooms/\(left.rawValue)/leave", [:])
        try await SearchStage.wait(30, "the edit, the deletion and the left room, live") {
            let old = try await stage.bodies("original"), new = try await stage.bodies("changed"), regret = try await stage.store.hits(match: "\"regretted\"", room: nil, kinds: Set(SearchKind.allCases), excluding: [], after: nil, limit: 5)
            let leave = try await stage.store.indexedRooms()
            return old.isEmpty && new == ["changed wording"] && regret.isEmpty && !leave.contains(left)
        }
        await stage.kill()
        await stage.store.suspend(rooms: [])
        try await server.edit(later, to: "replaced text", in: room)
        try await server.delete(gone, in: room)

        // Not listening, not even syncing: the check before showing finds out.
        let again = MatrixSessionPort(baseDirectory: directory)
        try await again.restore(stored)
        Cleanup.current.add { try? await again.logout() }
        stage = try SearchStage(again, directory: index, paused: true, clockAhead: 7_200)
        await stage.rooms.start()
        try await SearchStage.wait(30, "the room list") { await stage.rooms.rooms.contains { $0.id == room } }
        try await SearchStage.wait(20, "the changes made while away") {
            let deletedHits = try await stage.bodies("deleted"), editedHits = try await stage.bodies("edited")
            return deletedHits.isEmpty && editedHits == ["replaced text"]
        }
        try await SearchStage.wait(20, "the new text in the index") { try await stage.bodies("replaced") == ["replaced text"] }
        await stage.kill()
    }

    @Test("M20-11: room-filtered SearchPort returns only that room's matches and opens an older match via M20-1 focused jump", .timeLimit(.minutes(5)))
    func inRoomSearchAndFocusedJump() async throws {
        try await ProxyControl().heal()
        let (session, _, _) = try await signIn("inroom")
        let server = SearchServer(session: session)
        let roomA = try await server.makeRoom()
        let roomB = try await server.makeRoom()

        let olderID = try await server.send("compass milestone alpha", to: roomA)
        for index in 0..<25 { _ = try await server.send("filler message \(index)", to: roomA) }
        let newerID = try await server.send("compass milestone omega", to: roomA)
        _ = try await server.send("compass milestone decoy", to: roomB)

        let stage = try SearchStage(session)
        try await stage.start()
        try await SearchStage.wait(60, "room-scoped hits in roomA") {
            let page = try await stage.search.searchLocal(SearchQuery(text: "compass", room: roomA), after: nil)
            return page.hits.count == 2
        }

        let roomAPage = try await stage.search.searchLocal(SearchQuery(text: "compass", room: roomA), after: nil)
        #expect(roomAPage.hits.map(\.roomID) == [roomA, roomA])
        #expect(roomAPage.hits.map(\.eventID) == [newerID, olderID])

        // Jump to the older hit via M20-1 focused timeline.
        let timeline = TimelineCoordinator(port: MatrixTimelinePort(session: session), room: roomA)
        await timeline.open()
        try await SearchStage.wait(30, "live timeline ready") {
            if case .live = await timeline.status { return true }
            return false
        }
        try await timeline.focus(on: olderID)
        try await SearchStage.wait(30, "focused timeline shows older match") {
            guard case .live(let snapshot) = await timeline.status else { return false }
            return snapshot.focus == olderID && snapshot.items.contains {
                if case .event(let event) = $0.content { event.eventID == olderID } else { false }
            }
        }
        await timeline.close()
        await stage.kill()
    }

    // MARK: Helpers

    private func signIn(_ device: String) async throws -> (MatrixSessionPort, StoredSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-search-session-\(UUID().uuidString)")
        let session = MatrixSessionPort(baseDirectory: directory)
        let details = try await session.loginDetails(server: env["HALO_FAULT_SERVER"] ?? "")
        let stored = try await session.loginPassword(
            PasswordCredentials(username: env["HALO_FAULT_USER"] ?? "", password: env["HALO_FAULT_PASSWORD"] ?? "", deviceDisplayName: device), on: details)
        Cleanup.current.add { try? await session.logout() }
        return (session, stored, directory)
    }

    private func proxyPaths() async throws -> [String] {
        guard let url = URL(string: (env["HALO_FAULT_CONTROL"] ?? "") + "/stats") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return Array((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
    }
}
