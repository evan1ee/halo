import Testing
import HaloFoundation
@testable import HaloDomain

@Suite("OutgoingLocation and OutgoingPoll (D100)")
struct OutgoingSharesTests {
    @Test("geo URI has 6 decimals and the uncertainty; the body says whose location it is")
    func location() throws {
        let own = OutgoingLocation(latitude: 51.5007292, longitude: -0.1246254, accuracy: 12.4, isOwnLocation: true)
        #expect(own.geoURI == "geo:51.500729,-0.124625;u=12")
        #expect(own.body == "Location: 51.500729, -0.124625")
        let pin = OutgoingLocation(latitude: 0, longitude: 10.5, isOwnLocation: false)
        #expect(pin.geoURI == "geo:0,10.5" && pin.body == "Pinned location: 0, 10.5")
        try own.validate()
    }

    @Test("coordinates out of range are refused")
    func locationRange() {
        #expect(throws: HaloError.invalidInput("LOCATION_OUT_OF_RANGE")) { try OutgoingLocation(latitude: 91, longitude: 0, isOwnLocation: true).validate() }
        #expect(throws: HaloError.invalidInput("LOCATION_OUT_OF_RANGE")) { try OutgoingLocation(latitude: .nan, longitude: 0, isOwnLocation: false).validate() }
    }

    @Test("a poll trims, drops blank answers, and needs a question and 2–20 distinct answers")
    func poll() throws {
        let poll = OutgoingPoll(question: " Lunch? ", answers: ["Pizza ", "", " Sushi", "  "], allowsMultipleAnswers: true)
        #expect(poll.question == "Lunch?" && poll.answers == ["Pizza", "Sushi"] && poll.maxSelections == 2)
        try poll.validate()
        #expect(OutgoingPoll(question: "Q", answers: ["a", "b"]).maxSelections == 1)
        #expect(throws: HaloError.invalidInput("POLL_NO_QUESTION")) { try OutgoingPoll(question: " ", answers: ["a", "b"]).validate() }
        #expect(throws: HaloError.invalidInput("POLL_TOO_FEW_ANSWERS")) { try OutgoingPoll(question: "Q", answers: ["a", " "]).validate() }
        #expect(throws: HaloError.invalidInput("POLL_DUPLICATE_ANSWERS")) { try OutgoingPoll(question: "Q", answers: ["Yes", "yes"]).validate() }
        #expect(throws: HaloError.invalidInput("POLL_TOO_MANY_ANSWERS")) { try OutgoingPoll(question: "Q", answers: (1...21).map(String.init)).validate() }
        #expect(!OutgoingPoll(question: "Q", answers: ["a"]).isValid)
    }
}
