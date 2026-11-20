import Testing
@testable import HaloApplication

@Suite("UnrecognisedBotMessages")
struct UnrecognisedBotMessagesTests {
    @Test("counts distinct events once, however often a row is rebuilt")
    func counts() {
        let counter = UnrecognisedBotMessages()
        #expect(counter.count == 0)
        counter.record(eventID: "$a")
        counter.record(eventID: "$a")
        counter.record(eventID: "$b")
        #expect(counter.count == 2)
    }
}
