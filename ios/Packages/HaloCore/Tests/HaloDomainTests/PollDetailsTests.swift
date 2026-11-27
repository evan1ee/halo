import HaloDomain
import Testing

@Suite("PollDetails domain rules (M20-4)")
struct PollDetailsTests {
    @Test("single-choice vote selection, vote change, and no-op on already-selected or ended poll")
    func singleChoiceSelection() {
        let poll = PollDetails(
            question: "Lunch?",
            options: [
                PollOption(id: "a", text: "Pizza", votes: 2, selectedByMe: true),
                PollOption(id: "b", text: "Sushi", votes: 1, selectedByMe: false),
            ],
            visibility: .disclosed,
            maxSelections: 1,
            totalVoters: 3,
            ended: false
        )
        #expect(poll.ownSelectedIDs == ["a"])
        #expect(poll.showsResults)
        #expect(poll.nextSelection(tapping: "a", current: ["a"]) == nil)
        #expect(poll.nextSelection(tapping: "b", current: ["a"]) == ["b"])
        #expect(poll.nextSelection(tapping: "unknown", current: ["a"]) == nil)

        let ended = PollDetails(question: "Lunch?", options: poll.options, ended: true)
        #expect(ended.nextSelection(tapping: "b", current: ["a"]) == nil)
        #expect(ended.isWinner(poll.options[0]))
        #expect(!ended.isWinner(poll.options[1]))
    }

    @Test("multi-select toggles membership and respects maxSelections")
    func multiSelectSelection() {
        let poll = PollDetails(
            question: "Top 2?",
            options: [
                PollOption(id: "a", text: "One"),
                PollOption(id: "b", text: "Two"),
                PollOption(id: "c", text: "Three"),
            ],
            maxSelections: 2
        )
        #expect(poll.nextSelection(tapping: "a", current: []) == ["a"])
        #expect(poll.nextSelection(tapping: "b", current: ["a"]) == ["a", "b"])
        // Already at maxSelections (2): tapping a 3rd returns nil, tapping an existing one deselects it.
        #expect(poll.nextSelection(tapping: "c", current: ["a", "b"]) == nil)
        #expect(poll.nextSelection(tapping: "a", current: ["a", "b"]) == ["b"])
    }

    @Test("undisclosed polls hide results until ended; percentages and end fallback text")
    func visibilityPercentagesAndFallback() {
        let openUndisclosed = PollDetails(
            question: "Secret?",
            options: [
                PollOption(id: "y", text: "Yes", votes: 2),
                PollOption(id: "n", text: "No", votes: 1),
            ],
            visibility: .undisclosed,
            ended: false
        )
        #expect(!openUndisclosed.showsResults)
        #expect(openUndisclosed.votePercentage(for: openUndisclosed.options[0]) == 67)
        #expect(openUndisclosed.votePercentage(for: openUndisclosed.options[1]) == 33)

        let endedUndisclosed = PollDetails(
            question: "Secret?", options: openUndisclosed.options, visibility: .undisclosed, ended: true)
        #expect(endedUndisclosed.showsResults)
        #expect(endedUndisclosed.endFallbackText() == "Poll ended. Top result: Yes (2 votes).")

        let emptyPoll = PollDetails(question: "Anyone?", options: [PollOption(id: "a", text: "A")])
        #expect(emptyPoll.endFallbackText() == "Poll ended. No votes were cast.")
    }
}
