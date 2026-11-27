import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloMatrixAdapter

/// The wire-level half of the interoperability matrix (docs/testing/INTEGRATION_TESTS.md §4, ROADMAP M17-7): what Halo sends has the shape
/// the specification gives other clients, and what they send — as plain events, the way Element Web and Element X write them — becomes the right
/// kind of message. How it *looks* in those apps is the signed checklist. `infra/test/run.sh interop`; skipped otherwise.
@Suite("Interoperability", .serialized, .cleansUp, .enabled(if: TestServer.configured, "needs infra/test/run.sh interop"))
struct InteropTests {
    // MARK: Halo → others

    @Test("What Halo sends, as another client reads it", .timeLimit(.minutes(3)))
    func outgoing() async throws {
        let stage = try await TestStage()
        let timeline = stage.timeline, peerID = try UserID("@\(stage.user)peer:test.halo.localhost")
        let png = try #require(Data(base64Encoded: Self.pixel))
        let asked = try await stage.peer.send("question", to: stage.room)
        try await stage.wait(30, "the question") { stage.mirror.shows("question") }

        try await timeline.send(text: "plain", mentions: [])
        try await timeline.send(text: "hello @Peer", mentions: [Mention(user: peerID, name: "Peer")])
        try await timeline.send(text: "**bold** and `code`", mentions: [])
        try await timeline.reply(to: EventID(asked), text: "answer", mentions: [])
        try await timeline.send(text: "to edit", mentions: [])
        try await timeline.send(text: "to delete", mentions: [])
        try await timeline.toggleReaction(on: EventID(asked), key: "👍")
        try await timeline.sendImage(OutgoingImage(data: png, filename: "pixel.png", mimeType: "image/png", width: 1, height: 1))
        try await timeline.sendFile(OutgoingFile(data: Data("notes".utf8), filename: "notes.txt", mimeType: "text/plain"))
        try await timeline.sendFile(OutgoingFile(
            data: Data(count: 64), filename: "voice.m4a", mimeType: "audio/mp4",
            duration: 2.5, waveform: [0.0, 0.5, 1.0], isVoiceMessage: true))
        try await timeline.sendFile(OutgoingFile(
            data: Data(count: 64), filename: "clip.mp4", mimeType: "video/mp4",
            duration: 4.0, width: 1080, height: 1920, caption: "Portrait clip",
            thumbnail: OutgoingImage.Thumbnail(data: png, mimeType: "image/png", width: 1, height: 1)))
        try await timeline.sendLocation(OutgoingLocation(latitude: 52.5, longitude: 13.4, isOwnLocation: false))
        try await timeline.createPoll(OutgoingPoll(question: "Lunch?", answers: ["Yes", "No"]))
        let uri = try await stage.peer.upload(png, type: "image/png")
        try await timeline.sendSticker(Sticker(
            pack: PackRef(room: stage.room, stateKey: ""), shortcode: "cat", body: "cat", url: uri,
            info: StickerInfo(width: 1, height: 1, mimeType: "image/png", size: png.count)))

        for body in ["to edit", "to delete"] {
            try await stage.wait(60, "\(body) sent") { stage.mirror.own(body)?.sendState == .sent && stage.mirror.own(body)?.eventID != nil }
        }
        try await timeline.edit(event: #require(stage.mirror.own("to edit")?.eventID), newText: "edited")
        try await timeline.delete(event: #require(stage.mirror.own("to delete")?.eventID))
        try await stage.wait(60, "everything on the server") {
            let events = try await stage.peer.events(in: stage.room)
            return events.contains { $0["type"] as? String == "m.sticker" } && events.contains { $0["type"] as? String == "m.room.redaction" }
                && events.contains { relation($0)["rel_type"] as? String == "m.replace" }
        }

        let events = try await stage.peer.events(in: stage.room)
        func message(_ body: String) throws -> [String: Any] {
            try #require(events.compactMap(contents).first(where: { $0["body"] as? String == body }), "no event with body \(body)")
        }
        func info(_ content: [String: Any]) -> [String: Any] { content["info"] as? [String: Any] ?? [:] }

        let plain = try message("plain")
        #expect(plain["msgtype"] as? String == "m.text")
        let mention = try #require(events.compactMap(contents).first(where: { ($0["body"] as? String)?.hasPrefix("hello ") == true }))
        withKnownIssue("GA-30: the plain text of a mention carries the Markdown link") { #expect(mention["body"] as? String == "hello @Peer") }
        #expect((mention["m.mentions"] as? [String: Any])?["user_ids"] as? [String] == [peerID.rawValue])
        #expect((mention["formatted_body"] as? String)?.contains("matrix.to/#/") == true)
        let formatted = try message("**bold** and `code`")
        #expect(formatted["format"] as? String == "org.matrix.custom.html")
        #expect((formatted["formatted_body"] as? String)?.contains("<strong>bold</strong> and <code>code</code>") == true)
        let reply = try #require(events.compactMap(contents).first(where: { ($0["body"] as? String)?.contains("answer") == true }))
        #expect(((reply["m.relates_to"] as? [String: Any])?["m.in_reply_to"] as? [String: Any])?["event_id"] as? String == asked)
        let editEvent = try #require(events.first(where: { relation($0)["rel_type"] as? String == "m.replace" }))
        let edit = try #require(contents(editEvent))
        #expect((edit["m.new_content"] as? [String: Any])?["body"] as? String == "edited")
        #expect((edit["body"] as? String)?.hasPrefix("* ") == true, "the fallback other clients without edits show")
        let reaction = try #require(events.first(where: { $0["type"] as? String == "m.reaction" }))
        #expect(relation(reaction)["rel_type"] as? String == "m.annotation")
        #expect(relation(reaction)["event_id"] as? String == asked)
        #expect(relation(reaction)["key"] as? String == "👍" || relation(reaction)["key"] as? String == "👍️")

        let image = try message("pixel.png")
        #expect(image["msgtype"] as? String == "m.image")
        #expect((image["url"] as? String)?.hasPrefix("mxc://") == true)
        #expect(info(image)["mimetype"] as? String == "image/png")
        #expect(info(image)["w"] as? Int == 1 && info(image)["size"] as? Int == png.count)
        let file = try message("notes.txt")
        #expect(file["msgtype"] as? String == "m.file" && info(file)["size"] as? Int == 5)
        let voice = try message("voice.m4a")
        #expect(voice["msgtype"] as? String == "m.audio")
        #expect(voice["org.matrix.msc3245.voice"] != nil)
        let mscAudio = try #require(voice["org.matrix.msc1767.audio"] as? [String: Any])
        #expect(mscAudio["duration"] as? Int == 2500)
        #expect((mscAudio["waveform"] as? [Int])?.count == 3)
        let video = try message("Portrait clip")
        #expect(video["msgtype"] as? String == "m.video")
        #expect(video["filename"] as? String == "clip.mp4")
        #expect(info(video)["w"] as? Int == 1080 && info(video)["h"] as? Int == 1920 && info(video)["duration"] as? Int == 4000)
        #expect((info(video)["thumbnail_url"] as? String)?.hasPrefix("mxc://") == true)
        let location = try #require(events.compactMap(contents).first(where: { $0["msgtype"] as? String == "m.location" }))
        #expect((location["geo_uri"] as? String)?.hasPrefix("geo:52.5,13.4") == true)
        let pollEvent = try #require(events.first(where: { ($0["type"] as? String)?.hasSuffix("poll.start") == true }))
        let poll = try #require(contents(pollEvent))
        let start = try #require(poll["org.matrix.msc3381.poll.start"] as? [String: Any] ?? poll["m.poll"] as? [String: Any])
        #expect((start["answers"] as? [Any])?.count == 2)
        #expect(poll["org.matrix.msc1767.text"] != nil || poll["m.text"] != nil, "the fallback text")
        let stickerEvent = try #require(events.first(where: { $0["type"] as? String == "m.sticker" }))
        let sticker = try #require(contents(stickerEvent))
        #expect(sticker["body"] as? String == "cat" && sticker["url"] as? String == uri)
        #expect(events.contains { ($0["unsigned"] as? [String: Any])?["redacted_because"] != nil })
    }

    // MARK: Others → Halo

    @Test("What other clients send, as Halo shows it", .timeLimit(.minutes(4)))
    func incoming() async throws {
        let stage = try await TestStage()
        let png = try #require(Data(base64Encoded: Self.pixel))
        let uri = try await stage.peer.upload(png, type: "image/png")
        let cases = Self.cases(uri: uri)
        var ids: [String: String] = [:]
        for one in cases { ids[one.name] = try await stage.peer.send(one.content, type: one.type, to: stage.room) }
        let first = try #require(ids[cases[0].name])
        // Relations to the first message.
        let relations: [(String, String, [String: Any])] = [
            ("reply with fallback", "m.room.message", [
                "msgtype": "m.text", "body": "> <@x:y> plain text\n\nthe reply", "format": "org.matrix.custom.html",
                "formatted_body": "<mx-reply><blockquote>quoted</blockquote></mx-reply>the reply",
                "m.relates_to": ["m.in_reply_to": ["event_id": first]]]),
            ("edit", "m.room.message", [
                "msgtype": "m.text", "body": "* changed", "m.new_content": ["msgtype": "m.text", "body": "changed"],
                "m.relates_to": ["rel_type": "m.replace", "event_id": first]]),
            ("reaction", "m.reaction", ["m.relates_to": ["rel_type": "m.annotation", "event_id": first, "key": "🎉"]]),
            ("thread reply", "m.room.message", [
                "msgtype": "m.text", "body": "in the thread",
                "m.relates_to": ["rel_type": "m.thread", "event_id": first, "is_falling_back": true, "m.in_reply_to": ["event_id": first]]]),
        ]
        for (name, type, content) in relations { ids[name] = try await stage.peer.send(content, type: type, to: stage.room) }
        let gone = try await stage.peer.send("gone", to: stage.room)
        try await stage.peer.redact(gone, in: stage.room)
        let last = try await stage.peer.send("last", to: stage.room)
        try await stage.wait(60, "the last message") { stage.mirror.event(last) != nil }

        var missing: [String] = [], knownMissing: [String] = []
        for one in cases {
            guard let event = stage.mirror.event(ids[one.name] ?? "") else {
                if one.isKnownMissing { knownMissing.append(one.name) } else { missing.append("\(one.name): not in the timeline") }
                continue
            }
            if one.name != cases[0].name, !one.check(event) { missing.append("\(one.name): \(event.kind)") }
        }
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
        withKnownIssue("GA-31: the SDK leaves messages of a type it doesn't know out of the timeline") { #expect(knownMissing.isEmpty) }

        let edited = try #require(stage.mirror.event(first))
        #expect(edited.kind == .text("changed", isEdited: true))
        #expect(edited.reactions.map(\.key) == ["🎉"])
        let reply = try #require(stage.mirror.event(ids["reply with fallback"] ?? ""))
        #expect(reply.replyTo?.eventID.rawValue == first)
        if case .text(let body, _) = reply.kind { #expect(!body.contains("> <@x:y>"), "the reply fallback is stripped: \(body)") } else { Issue.record("\(reply.kind)") }
        #expect(stage.mirror.event(gone)?.kind == .redacted)
    }

    struct Incoming {
        let name: String
        var type = "m.room.message"
        let content: [String: Any]
        var isKnownMissing = false
        let check: (TimelineEvent) -> Bool
    }

    /// Event contents as the Matrix specification, MSC3381 (polls), MSC3488 (location) and MSC3245 (voice) give them.
    static func cases(uri: String) -> [Incoming] {
        func media(_ event: TimelineEvent, _ kind: MediaKind) -> MediaAttachment? {
            if case .media(let media) = event.kind, media.kind == kind { return media }
            return nil
        }
        func isText(_ event: TimelineEvent, _ body: String) -> Bool { event.kind == .text(body, isEdited: false) }
        return [
            Incoming(name: "text", content: ["msgtype": "m.text", "body": "plain text"]) { isText($0, "plain text") },
            Incoming(name: "formatted", content: [
                "msgtype": "m.text", "body": "bold", "format": "org.matrix.custom.html", "formatted_body": "<strong>bold</strong>"
            ]) { isText($0, "bold") && $0.formattedBody == "<strong>bold</strong>" },
            Incoming(name: "notice", content: ["msgtype": "m.notice", "body": "from a bot"]) { $0.kind == .notice("from a bot", isEdited: false) },
            Incoming(name: "emote", content: ["msgtype": "m.emote", "body": "waves"]) { $0.kind == .emote("waves", isEdited: false) },
            Incoming(name: "image", content: [
                "msgtype": "m.image", "body": "p.png", "url": uri, "info": ["mimetype": "image/png", "w": 640, "h": 480, "size": 70]
            ]) { media($0, .image)?.width == 640 && media($0, .image)?.source != nil },
            Incoming(name: "image with caption", content: [
                "msgtype": "m.image", "body": "a caption", "filename": "p.png", "url": uri, "info": ["mimetype": "image/png"]
            ]) { media($0, .image) != nil },
            Incoming(name: "image without info", content: ["msgtype": "m.image", "body": "bare.png", "url": uri]) { media($0, .image) != nil },
            Incoming(name: "video", content: [
                "msgtype": "m.video", "body": "Beach clip", "filename": "v.mp4", "url": uri,
                "info": ["mimetype": "video/mp4", "w": 320, "h": 240, "duration": 2500, "thumbnail_url": uri, "thumbnail_info": ["mimetype": "image/png"]]
            ]) { media($0, .video)?.duration == 2.5 && media($0, .video)?.thumbnail != nil && media($0, .video)?.caption == "Beach clip" },
            Incoming(name: "audio", content: [
                "msgtype": "m.audio", "body": "a.ogg", "url": uri, "info": ["mimetype": "audio/ogg", "duration": 1500]
            ]) { media($0, .audio)?.duration == 1.5 },
            Incoming(name: "voice message", content: [
                "msgtype": "m.audio", "body": "Voice message", "url": uri, "info": ["mimetype": "audio/ogg", "duration": 3000, "size": 100],
                "org.matrix.msc1767.audio": ["duration": 3000, "waveform": [0, 512, 1024]], "org.matrix.msc3245.voice": [String: Any]()
            ]) {
                guard let audio = media($0, .audio) else { return false }
                return audio.duration == 3 && audio.isVoice && audio.waveform == [0, 0.5, 1]
            },
            Incoming(name: "file", content: [
                "msgtype": "m.file", "body": "d.pdf", "filename": "d.pdf", "url": uri, "info": ["mimetype": "application/pdf", "size": 999]
            ]) { media($0, .file)?.size == 999 },
            Incoming(name: "location", content: [
                "msgtype": "m.location", "body": "Berlin", "geo_uri": "geo:52.5,13.4;u=10",
                "org.matrix.msc3488.location": ["uri": "geo:52.5,13.4;u=10"], "org.matrix.msc3488.asset": ["type": "m.pin"]
            ]) { if case .location(_, let geo) = $0.kind { geo.hasPrefix("geo:52.5,13.4") } else { false } },
            Incoming(name: "poll", type: "org.matrix.msc3381.poll.start", content: [
                "org.matrix.msc3381.poll.start": [
                    "question": ["org.matrix.msc1767.text": "Where?"], "kind": "org.matrix.msc3381.poll.disclosed", "max_selections": 1,
                    "answers": [["id": "a", "org.matrix.msc1767.text": "Here"], ["id": "b", "org.matrix.msc1767.text": "There"]]],
                "org.matrix.msc1767.text": "Where?\n1. Here\n2. There"
            ]) {
                if case .poll(let details) = $0.kind {
                    details.question == "Where?" && details.options.count == 2 && !details.ended && details.visibility == .disclosed
                } else { false }
            },
            Incoming(name: "sticker", type: "m.sticker", content: [
                "body": "cat", "url": uri, "info": ["mimetype": "image/png", "w": 128, "h": 128]
            ]) { if case .sticker("cat", let source, let url, _) = $0.kind { source != nil && url == uri } else { false } },
            Incoming(name: "unknown msgtype shows its fallback", content: ["msgtype": "com.example.new", "body": "fallback text"], isKnownMissing: true) {
                switch $0.kind {
                case .text("fallback text", _), .unsupported: true
                default: false
                }
            },
        ]
    }

    /// A 1 × 1 PNG.
    static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    // MARK: Polls with two accounts (M20-4, AC-M5)

    @Test("Polls: two accounts vote, change vote leaves one vote per person, and creator ends own poll", .timeLimit(.minutes(3)))
    func pollsTwoAccounts() async throws {
        let stage = try await TestStage()
        try await stage.timeline.createPoll(OutgoingPoll(question: "Dinner?", answers: ["Pizza", "Sushi"]))

        func currentPoll() -> (eventID: EventID, details: PollDetails)? {
            stage.mirror.poll(question: "Dinner?")
        }

        try await stage.wait(30, "poll created") { currentPoll() != nil }
        let initial = try #require(currentPoll())
        let pizza = try #require(initial.details.options.first { $0.text == "Pizza" })
        let sushi = try #require(initial.details.options.first { $0.text == "Sushi" })

        // Account 1 votes Pizza.
        try await stage.timeline.votePoll(pollEventID: initial.eventID, answers: [pizza.id])
        try await stage.wait(30, "account 1 vote echoed") {
            guard let poll = currentPoll()?.details else { return false }
            return poll.options.first { $0.id == pizza.id }?.votes == 1
                && poll.options.first { $0.id == pizza.id }?.selectedByMe == true
                && poll.totalVoters == 1
        }

        // Account 2 votes Sushi (raw MSC3381 poll response).
        _ = try await stage.peer.send(
            [
                "org.matrix.msc3381.poll.response": ["answers": [sushi.id]],
                "m.relates_to": ["rel_type": "m.reference", "event_id": initial.eventID.rawValue],
            ],
            type: "org.matrix.msc3381.poll.response",
            to: stage.room
        )
        try await stage.wait(30, "account 2 vote echoed") {
            guard let poll = currentPoll()?.details else { return false }
            return poll.options.first { $0.id == pizza.id }?.votes == 1
                && poll.options.first { $0.id == sushi.id }?.votes == 1
                && poll.totalVoters == 2
        }

        // Account 1 changes vote to Sushi → leaves one vote per person (Pizza=0, Sushi=2, totalVoters=2, AC-M5).
        try await stage.timeline.votePoll(pollEventID: initial.eventID, answers: [sushi.id])
        try await stage.wait(30, "account 1 changed vote") {
            guard let poll = currentPoll()?.details else { return false }
            return poll.options.first { $0.id == pizza.id }?.votes == 0
                && poll.options.first { $0.id == pizza.id }?.selectedByMe == false
                && poll.options.first { $0.id == sushi.id }?.votes == 2
                && poll.options.first { $0.id == sushi.id }?.selectedByMe == true
                && poll.totalVoters == 2
        }

        // Creator ends the poll.
        let latest = try #require(currentPoll()?.details)
        try await stage.timeline.endPoll(pollEventID: initial.eventID, fallbackText: latest.endFallbackText())
        try await stage.wait(30, "poll ended") { currentPoll()?.details.ended == true }
        let finalPoll = try #require(currentPoll()?.details)
        #expect(finalPoll.ended)
        #expect(finalPoll.options.first { $0.id == sushi.id }?.votes == 2)
    }

    // MARK: Forward encrypted photo & multiple types to several targets (M20-6, AC-M4)

    @Test("Forward: encrypted photo re-encrypts for an encrypted target and isn't readable by the server (AC-M4)", .timeLimit(.minutes(3)))
    func forwardEncryptedPhotoAndTypes() async throws {
        let stage = try await TestStage()
        let timelinePort = MatrixTimelinePort(session: stage.session)
        let mediaPort = MatrixMediaPort(session: stage.session)
        let forwarder = ForwardCoordinator(timeline: timelinePort, media: mediaPort)

        // Create two encrypted rooms (source + encrypted target) and join Account 1 to both.
        let encSource = try await stage.peer.makeEncryptedRoom()
        let encTarget = try await stage.peer.makeEncryptedRoom()
        let plainTarget = stage.room
        let selfPeer = try await TestPeer(server: stage.direct, user: stage.user, password: stage.password)
        try await selfPeer.join(encSource)
        try await selfPeer.join(encTarget)
        await selfPeer.logout()

        func openRoom(_ id: RoomID) async throws -> any TimelineSession {
            for _ in 0..<60 {
                if let opened = try? await timelinePort.open(room: id) { return opened }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw ContractViolation("couldn't open room \(id.rawValue)")
        }

        let sourceSession = try await openRoom(encSource)
        let sourceMirror = TimelineMirror(sourceSession.items())
        let targetEncSession = try await openRoom(encTarget)
        let targetEncMirror = TimelineMirror(targetEncSession.items())

        // Send a real PNG photo into Encrypted Room A.
        let png = try #require(Data(base64Encoded: Self.pixel))
        try await sourceSession.sendImage(OutgoingImage(
            data: png, filename: "secret.png", mimeType: "image/png", width: 1, height: 1, caption: "Top secret"
        ))
        try await stage.wait(30, "encrypted source photo confirmed") {
            sourceMirror.ownMedia(named: "Top secret", confirmedOnly: true) != nil
        }
        let sourcePhoto = try #require(sourceMirror.ownMedia(named: "Top secret", confirmedOnly: true))
        let sourceRef = try #require(sourcePhoto.source)

        // Forward that encrypted photo simultaneously to Encrypted Room B and Unencrypted Room C.
        let photoOutcome = await forwarder.forward(
            .image(ref: sourceRef, filename: "secret.png", mimeType: "image/png", width: 1, height: 1, caption: "Top secret"),
            to: [encTarget, plainTarget]
        )
        #expect(photoOutcome.isCompleteSuccess)
        #expect(photoOutcome.succeeded == [encTarget, plainTarget])

        // Verify Encrypted Room B received the forwarded photo, re-encrypted with a fresh ref, and decrypts to exact PNG bytes.
        try await stage.wait(30, "forwarded photo confirmed in encrypted target") {
            targetEncMirror.ownMedia(named: "Top secret", confirmedOnly: true) != nil
        }
        let encTargetPhoto = try #require(targetEncMirror.ownMedia(named: "Top secret", confirmedOnly: true))
        let encTargetRef = try #require(encTargetPhoto.source)
        #expect(encTargetRef != sourceRef, "re-encrypted upload must have a new key/IV/URL")
        let decryptedEncBytes = try await mediaPort.content(encTargetRef)
        #expect(decryptedEncBytes == png)

        // Server view of Encrypted Room B must contain ciphertext (`m.room.encrypted`), never plaintext `m.room.message` (AC-M4).
        let encServerEvents = try await stage.peer.events(in: encTarget)
        #expect(encServerEvents.contains { $0["type"] as? String == "m.room.encrypted" })
        #expect(!encServerEvents.contains {
            $0["type"] as? String == "m.room.message" && (contents($0)?["body"] as? String) == "Top secret"
        })

        // Verify Unencrypted Room C also received the photo with exact PNG bytes.
        try await stage.wait(30, "forwarded photo confirmed in plain target") {
            stage.mirror.ownMedia(named: "Top secret", confirmedOnly: true) != nil
        }
        let plainRef = try #require(stage.mirror.ownMedia(named: "Top secret", confirmedOnly: true)?.source)
        #expect(try await mediaPort.content(plainRef) == png)

        // Also forward a location + sticker to both targets.
        let stickerURI = try await stage.peer.upload(png, type: "image/png")
        let locOutcome = await forwarder.forward(
            .location(OutgoingLocation(latitude: 52.5, longitude: 13.4, description: "Spot", isOwnLocation: false)),
            to: [encTarget, plainTarget]
        )
        #expect(locOutcome.isCompleteSuccess)
        let stickerOutcome = await forwarder.forward(
            .sticker(body: "Wave", url: stickerURI, info: StickerInfo(width: 1, height: 1, mimeType: "image/png", size: png.count)),
            to: [encTarget, plainTarget]
        )
        #expect(stickerOutcome.isCompleteSuccess)
        try await stage.wait(30, "forwarded location and sticker on server") {
            let plainEvents = try await stage.peer.events(in: plainTarget)
            return plainEvents.contains { $0["type"] as? String == "m.sticker" && (contents($0)?["url"] as? String) == stickerURI }
                && plainEvents.contains { contents($0)?["msgtype"] as? String == "m.location" }
        }
    }

    // MARK: Room lifecycle: upgraded successor, knock, banned, left & forgotten (M20-8, GA-23)

    @Test("Room lifecycle: tombstoned successor, knock request & cancel, banned forget, and left forget", .timeLimit(.minutes(3)))
    func roomLifecycleStates() async throws {
        let stage = try await TestStage()
        let roomPort = MatrixRoomPort(session: stage.session)

        // 1. Upgraded room (`m.room.tombstone`, GA-23): successor ID & reason surface in RoomDetails.
        let replacementRoom = try await stage.peer.makeRoom()
        try await stage.peer.tombstone(stage.room, replacement: replacementRoom, reason: "Upgraded to v11")
        try await stage.wait(30, "tombstone synced into room details") {
            let details = try? await roomPort.details(stage.room)
            return details?.successor == RoomSuccessor(roomID: replacementRoom, reason: "Upgraded to v11")
        }

        // 2. Knock room: preview → knock → appears as .knocked in inactiveRooms → cancel (leave + forget) removes it cleanly.
        let knockRoom = try await stage.peer.makeKnockRoom(name: "Knock Room")
        let knockedID = try await roomPort.knock(address: knockRoom.rawValue, reason: "Hello")
        #expect(knockedID == knockRoom)
        try await stage.wait(30, "knocked room appears in inactiveRooms") {
            await roomPort.inactiveRooms().contains { $0.id == knockRoom && $0.membership == .knocked }
        }
        try await roomPort.leave(knockRoom)
        try? await roomPort.forget(knockRoom)

        // 3. Banned room: peer bans user → appears as .banned → forget succeeds cleanly.
        let banRoom = try await stage.peer.makeRoom()
        let selfPeer = try await TestPeer(server: stage.direct, user: stage.user, password: stage.password)
        try await selfPeer.join(banRoom)
        await selfPeer.logout()
        try await stage.wait(30, "joined ban test room") {
            (try? await roomPort.details(banRoom).membership) == .joined
        }
        let ownUserID = try await stage.session.ownUserID()
        try await stage.peer.ban(user: ownUserID, from: banRoom)
        try await stage.wait(30, "banned room synced") {
            await roomPort.inactiveRooms().contains { $0.id == banRoom && $0.membership == .banned }
        }
        try await roomPort.forget(banRoom)

        // 4. Leave & forget the tombstoned room.
        try await roomPort.leave(stage.room)
        try await roomPort.forget(stage.room)
    }

    // MARK: Read receipts under others' messages & receipt timestamps (M20-9, TIMELINE FR-6)

    @Test("Read receipts: others' messages surface other readers with timestamps, excluding self and sender", .timeLimit(.minutes(2)))
    func readReceiptsOnOthersMessagesAndTimestamps() async throws {
        let stage = try await TestStage()
        let ownUserID = try await stage.session.ownUserID()
        // Third user (`${user}third`, provisioned by `infra/test/run.sh`) joins the room so we can verify receipts
        // on BOTH someone else's message (peer's) and Halo's own message.
        let serverDomain = String(ownUserID.split(separator: ":").last ?? "")
        let peerUserID = try UserID("@\(stage.user)peer:\(serverDomain)")
        let thirdLocal = "\(stage.user)third"
        let thirdUserID = try UserID("@\(thirdLocal):\(serverDomain)")
        let third = try await TestPeer(server: stage.direct, user: thirdLocal, password: stage.password)
        Cleanup.current.add { await third.logout() }
        try await third.join(stage.room)

        // Peer sends a message (someone else's message from Halo's POV).
        let peerEventID = try await stage.peer.send("Peer message for receipts", to: stage.room)
        try await stage.wait(20, "peer message arrives") {
            stage.mirror.event(peerEventID) != nil
        }

        // Third user sends a public read receipt on peer's message.
        try await third.sendReadReceipt(for: peerEventID, in: stage.room)
        try await stage.wait(20, "third user's read receipt surfaces on peer's message") {
            guard let e = stage.mirror.event(peerEventID) else { return false }
            return e.readReceipts.contains { $0.userID == thirdUserID && $0.timestamp != nil }
                && !e.readBy.contains(peerUserID)
                && e.readBy.allSatisfy { $0.rawValue != ownUserID }
        }

        // Halo sends an own message; peer reads it → peer appears with timestamp.
        try await stage.timeline.send(text: "Halo message for receipts")
        try await stage.wait(20, "own message confirmed") {
            stage.mirror.own("Halo message for receipts")?.eventID != nil
        }
        let ownEventID = try #require(stage.mirror.own("Halo message for receipts")?.eventID?.rawValue)
        try await stage.peer.sendReadReceipt(for: ownEventID, in: stage.room)
        try await stage.wait(20, "peer receipt surfaces on own message with timestamp") {
            guard let e = stage.mirror.own("Halo message for receipts") else { return false }
            return e.readReceipts.contains { $0.userID == peerUserID && $0.timestamp != nil }
        }
    }
}

private func contents(_ event: [String: Any]) -> [String: Any]? { event["content"] as? [String: Any] }
private func relation(_ event: [String: Any]) -> [String: Any] { contents(event)?["m.relates_to"] as? [String: Any] ?? [:] }
