import XCTest

/// UI smoke tests and automated accessibility audits for Halo (`docs/ROADMAP.md` M14, TD-03, AC-UX-8).
final class HaloUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        var failures: [String] = []
        try app.performAccessibilityAudit { issue in
            // WCAG 2.1 SC 1.4.3 exempts inactive/disabled controls (e.g. SwiftUI .borderedProminent .disabled(true)).
            if issue.auditType == .contrast, let element = issue.element, !element.isEnabled {
                return true
            }
            // Ignore Apple's system keyboard predictive-text cells (TextInputUI), outside Halo's view hierarchy.
            if issue.detailedDescription.contains("TUIPredictionViewCell") {
                return true
            }
            let label = issue.element?.label ?? "unknown"
            let type = issue.element?.elementType.rawValue ?? 0
            failures.append("\(issue.compactDescription) | \(issue.detailedDescription) | label='\(label)' type=\(type)")
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
        try app.performAccessibilityAudit()
    }
}
