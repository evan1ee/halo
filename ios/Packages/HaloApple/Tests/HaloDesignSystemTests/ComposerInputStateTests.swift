import Testing
@testable import HaloDesignSystem

@Suite("ComposerInputState")
struct ComposerInputStateTests {
    @Test("tapping the field shows the keyboard; losing focus ends it")
    func keyboard() {
        var state = ComposerInputState()
        state.fieldFocused()
        #expect(state.mode == .keyboard && state.wantsFieldFocus)
        state.fieldUnfocused()
        #expect(state.mode == .idle && !state.wantsFieldFocus)
    }

    @Test("a panel toggle opens the panel, a second tap swaps it back for the keyboard")
    func toggle() {
        var state = ComposerInputState(mode: .keyboard)
        state.toggle(.expression)
        #expect(state.panel == .expression && !state.wantsFieldFocus && state.showsKeyboardToggle(for: .expression))
        // The field losing focus because the panel opened must not close the panel.
        state.fieldUnfocused()
        #expect(state.panel == .expression)
        state.toggle(.expression)
        #expect(state.mode == .keyboard && state.lingeringPanel == .expression && state.displayedPanel == .expression)
        state.keyboardCoversLingeringPanel()
        #expect(state.displayedPanel == nil)
    }

    @Test("switching between panels replaces the open one directly")
    func switchPanels() {
        var state = ComposerInputState(mode: .panel(.attachments))
        state.toggle(.expression)
        #expect(state.panel == .expression && state.lingeringPanel == nil)
    }

    @Test("a keyboard raised inside an open panel is the panel's search; hiding it restores the panel")
    func panelSearch() {
        var state = ComposerInputState(mode: .panel(.expression))
        state.keyboardWillShow()
        #expect(state.panelSearching && state.panel == .expression)
        state.keyboardWillHide()
        #expect(!state.panelSearching && state.panel == .expression)
    }

    @Test("the keyboard hiding by itself (interactive dismissal) ends keyboard mode")
    func keyboardHides() {
        var state = ComposerInputState(mode: .keyboard)
        state.keyboardWillShow()
        #expect(!state.panelSearching)
        state.keyboardWillHide()
        #expect(state.mode == .idle)
    }

    @Test("dismiss closes everything")
    func dismiss() {
        var state = ComposerInputState(mode: .panel(.attachments))
        state.keyboardWillShow()
        state.dismiss()
        #expect(state == ComposerInputState())
    }

    @Test("panel height follows the docked keyboard within bounds; hardware keyboard bars don't shrink it")
    func panelHeight() {
        #expect(ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: nil) == ComposerPanelMetrics.minimumHeight)
        #expect(ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: 302) == 302)
        #expect(ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: 55) == ComposerPanelMetrics.minimumHeight)
        #expect(ComposerPanelMetrics.panelHeight(lastKeyboardOverlap: 900) == ComposerPanelMetrics.maximumHeight)
    }

    @Test("while the keyboard and a panel swap, keyboard cover plus panel area stays the panel height")
    func handOver() {
        let height = 300.0
        let opening = ComposerInputState(mode: .panel(.expression))
        for overlap in stride(from: 300.0, through: 0, by: -50) {
            #expect(ComposerPanelMetrics.areaHeight(state: opening, panelHeight: height, keyboardOverlap: overlap) + overlap == height)
        }
        var closing = ComposerInputState(mode: .panel(.expression))
        closing.fieldFocused()
        for overlap in stride(from: 0.0, through: 300, by: 50) {
            #expect(ComposerPanelMetrics.areaHeight(state: closing, panelHeight: height, keyboardOverlap: overlap) + overlap == height)
        }
        #expect(ComposerPanelMetrics.areaHeight(state: ComposerInputState(mode: .keyboard), panelHeight: height, keyboardOverlap: 300) == 0)
        var searching = ComposerInputState(mode: .panel(.expression))
        searching.keyboardWillShow()
        #expect(ComposerPanelMetrics.areaHeight(state: searching, panelHeight: height, keyboardOverlap: 300) == ComposerPanelMetrics.searchHeight)
    }
}

@Suite("ComposerInputController")
@MainActor
struct ComposerInputControllerTests {
    @Test("keyboard changes size the panels and drive the state")
    func keyboardEvents() {
        let controller = ComposerInputController()
        controller.fieldFocusChanged(true)
        controller.apply(isHiding: false, overlap: 291, duration: 0.25)
        #expect(controller.lastKeyboardOverlap == 291 && controller.panelHeight == 291)
        controller.toggle(.expression)
        #expect(controller.areaHeight == 0)  // still under the keyboard
        controller.apply(isHiding: true, overlap: 0, duration: 0.25)
        #expect(controller.areaHeight == 291 && controller.state.panel == .expression)
        // A hardware keyboard's bar while searching doesn't resize the panels.
        controller.apply(isHiding: false, overlap: 55, duration: 0.25)
        #expect(controller.state.panelSearching && controller.panelHeight == 291)
        controller.dismiss()
        #expect(controller.state.mode == .idle)
    }
}
