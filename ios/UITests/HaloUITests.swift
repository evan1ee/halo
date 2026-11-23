import XCTest

/// UI smoke tests and automated accessibility audits for Halo (`docs/ROADMAP.md` M14, TD-03, AC-UX-8).
final class HaloUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        var failures: [String] = []
        // iOS 26 floats the search field over the bottom of the chat list and blurs the strip around it, so the text of a
        // row resting under it is measured through system glass. That row passes once scrolled up; only contrast findings
        // for text reaching the field's top edge are skipped (founder decision, 2026-11-22).
        let searchField = app.searchFields.firstMatch
        let glassTop = searchField.exists ? searchField.frame.minY : .infinity
        try app.performAccessibilityAudit { issue in
            // WCAG 2.1 SC 1.4.3 exempts inactive/disabled controls (e.g. SwiftUI .borderedProminent .disabled(true)).
            if issue.auditType == .contrast, let element = issue.element, !element.isEnabled {
                return true
            }
            // The accent is Apple's system blue (#007AFF, founder decision), ~4.0:1 on white: the audit reports link text
            // in it as "nearly passed". Genuine contrast failures still fail.
            if issue.auditType == .contrast, issue.compactDescription.contains("nearly passed") {
                return true
            }
            if issue.auditType == .contrast, let element = issue.element, element.frame.maxY > glassTop {
                return true
            }
            // Rows resting under or partially clipped below the floating search field can report `element == nil` for
            // their inner `.accessibilityElement(children: .ignore)` nodes (D96, amended 2026-11-23). Any finding with a
            // resolved element above `glassTop` still fails.
            if glassTop < .infinity, issue.element == nil,
               issue.auditType == .contrast || issue.auditType == .textClipped {
                return true
            }
            // Ignore Apple's system keyboard predictive-text cells (TextInputUI), outside Halo's view hierarchy.
            if issue.detailedDescription.contains("TUIPredictionViewCell") {
                return true
            }
            let label = issue.element?.label ?? "unknown"
            let type = issue.element?.elementType.rawValue ?? 0
            let frame = issue.element.map { "\($0.frame)" } ?? "?"
            failures.append("\(issue.compactDescription) | \(issue.detailedDescription) | label='\(label)' type=\(type) frame=\(frame)")
            return true
        }
        if !failures.isEmpty {
            XCTFail("Accessibility audit found \(failures.count) issue(s):\n" + failures.joined(separator: "\n"))
        }
    }

    @MainActor
    func testLaunchRootScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()

        // The app launches either into SignInView (signed out) or Chats (signed in).
        let signInVisible = app.staticTexts["Halo"].waitForExistence(timeout: 5)
        let chatsVisible = app.navigationBars["Chats"].waitForExistence(timeout: 2)
        XCTAssertTrue(signInVisible || chatsVisible, "Expected either Sign in or Chats root screen")

        try audit(app)

        // A Focus filter shows a banner and hides most chats: audit the full chat list as well.
        let showAll = app.buttons["focus-show-all"]
        if showAll.exists {
            showAll.tap()
            XCTAssertTrue(showAll.waitForNonExistence(timeout: 2))
            try audit(app)
        }
    }

    @MainActor
    func testSignInInlineHelpTogglesAndPassesAudit() throws {
        let app = XCUIApplication()
        app.launch()

        let helpButton = app.buttons["What's a homeserver?"]
        guard helpButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("App is already signed in; skipping signed-out onboarding audit.")
        }

        helpButton.tap()
        let explanation = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "homeserver")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 2))

        try audit(app)
    }

    /// Optional golden-path test against a running `infra/dev` homeserver.
    /// Set `HALO_UI_TEST_HOMESERVER`, `HALO_UI_TEST_USER`, and `HALO_UI_TEST_PASSWORD` to run.
    @MainActor
    func testGoldenPathAgainstDevHomeserver() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["HALO_UI_TEST_HOMESERVER"],
              let user = env["HALO_UI_TEST_USER"],
              let password = env["HALO_UI_TEST_PASSWORD"] else {
            throw XCTSkip("Set HALO_UI_TEST_HOMESERVER, HALO_UI_TEST_USER, HALO_UI_TEST_PASSWORD to run golden-path UI test.")
        }

        let app = XCUIApplication()
        app.launch()

        if app.buttons["Sign in"].waitForExistence(timeout: 5) {
            let serverField = app.textFields.firstMatch
            if serverField.exists {
                serverField.tap()
                serverField.typeText(server)
            }
            let nextButton = app.buttons["Continue"]
            if nextButton.exists { nextButton.tap() }
            let userField = app.textFields["Username"]
            if userField.waitForExistence(timeout: 5) {
                userField.tap()
                userField.typeText(user)
            }
            let passwordField = app.secureTextFields["Password"]
            if passwordField.waitForExistence(timeout: 5) {
                passwordField.tap()
                passwordField.typeText(password)
            }
            app.buttons["Sign in"].tap()
        }

        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 15))
        try audit(app)
    }

    /// M4/M5 simulator UI check: opens a chat, verifies the sticker panel loads packs/stickers, and exercises New pack creation.
    @MainActor
    func testStickerPanelAndPackCreationFlow() throws {
        let app = XCUIApplication()
        app.launch()

        if !app.navigationBars["Chats"].waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        guard app.navigationBars["Chats"].waitForExistence(timeout: 5) else {
            throw XCTSkip("App is signed out; skipping signed-in sticker panel UI check.")
        }

        let showAll = app.buttons["focus-show-all"]
        if showAll.exists {
            showAll.tap()
            _ = showAll.waitForNonExistence(timeout: 2)
        }

        // Open the first non-gallery chat row so the composer (and its sticker button) is shown.
        let cells = app.collectionViews.firstMatch.cells
        guard cells.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("No chats available on this simulator.")
        }
        var openedChat = false
        for index in 0..<min(cells.count, 5) {
            let cell = cells.element(boundBy: index)
            if cell.staticTexts["Media Gallery"].exists { continue }
            cell.tap()
            if app.buttons["sticker-button"].waitForExistence(timeout: 5) {
                openedChat = true
                break
            }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        guard openedChat else {
            throw XCTSkip("No room with a sticker button found on this simulator.")
        }

        app.buttons["sticker-button"].tap()
        let search = app.textFields["sticker-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Sticker panel should show search field")
        let loading = app.staticTexts["Loading stickers…"]
        if loading.exists {
            XCTAssertTrue(loading.waitForNonExistence(timeout: 5), "Sticker panel should finish loading")
        }

        // Open pack creation from the sticker panel (+ button or empty-state button).
        let newPackButton = app.buttons["new-pack"].exists ? app.buttons["new-pack"] : app.buttons["New sticker pack"]
        XCTAssertTrue(newPackButton.waitForExistence(timeout: 3), "Expected New pack button in sticker panel")
        newPackButton.tap()

        XCTAssertTrue(app.navigationBars["New pack"].waitForExistence(timeout: 5), "New pack sheet should appear")
        let nameField = app.textFields["pack-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Test Pack")
        XCTAssertFalse(app.buttons["Create"].isEnabled, "Create must stay disabled until at least one sticker is added")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["New pack"].waitForNonExistence(timeout: 3), "Cancel should dismiss New pack sheet")

        // Dismiss the sticker panel and return to Chats so @SceneStorage restores at the root for subsequent tests.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        _ = search.waitForNonExistence(timeout: 3)
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5), "Should return to Chats root")
    }

    /// Cold-launch performance metric (ROADMAP M15, SR-06, NFR-1).
    /// Opt-in via `HALO_RUN_PERF_TESTS=1` so routine `prepush.sh` runs stay fast.
    @MainActor
    func testLaunchPerformanceMetric() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_PERF_TESTS=1 to run XCTApplicationLaunchMetric.")
        }
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
