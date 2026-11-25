import XCTest

/// The measurements behind the release budgets (TEST_STRATEGY §7, ROADMAP M17-5). `scripts/perf.py` runs them, reads the values from the
/// result bundle and compares them with the budgets; on their own they only record. Opt-in: `HALO_RUN_PERF_TESTS=1`.
final class HaloPerformanceTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["HALO_RUN_PERF_TESTS"] == "1" else { throw XCTSkip("Run by scripts/perf.py (HALO_RUN_PERF_TESTS=1).") }
    }

    /// Signs in on a fresh simulator (`HALO_PERF_SERVER/USER/PASSWORD`) and waits until the account has synced; first in order.
    @MainActor
    func test0SignIn() throws {
        let app = launch()
        let server = app.textFields["Homeserver"]
        if server.waitForExistence(timeout: 8) {
            guard let address = env["HALO_PERF_SERVER"], let user = env["HALO_PERF_USER"], let password = env["HALO_PERF_PASSWORD"] else {
                throw XCTSkip("Signed out, and no account to sign in with.")
            }
            replaceText(of: server, with: address + "\n")  // the keyboard's own "Continue" shares the button's name
            let name = app.textFields["Username"]
            XCTAssertTrue(name.waitForExistence(timeout: 20), "The server offers password sign-in")
            name.tap()
            name.typeText(user)
            app.secureTextFields["Password"].tap()
            app.secureTextFields["Password"].typeText(password)
            app.buttons["Sign in"].tap()
        }
        dismissSheets(app, for: 30)
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 60), "Signed in")
        XCTAssertTrue(rooms(app).firstMatch.waitForExistence(timeout: 300), "The chats arrive")
        // The first sync goes on after the first rows; the other tests measure the settled app.
        Thread.sleep(forTimeInterval: Double(env["HALO_PERF_SETTLE"] ?? "") ?? 10)
        dismissSheets(app, for: 4)
    }

    /// NFR-1: launch → first frame, as iOS measures it.
    @MainActor
    func test1Launch() throws {
        try requireSignedIn()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) { application().launch() }
    }

    /// NFR-1: launch → the room list has its rows (`cold-start`). Apart from `test1Launch`: the launch metric ends the recording too early for it.
    @MainActor
    func test1ColdStart() throws {
        try requireSignedIn()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [signpost("cold-start"), signpost("main-thread-hang")], options: options) {
            let app = launch()
            _ = app.buttons["settings"].waitForExistence(timeout: 20)
            app.terminate()
        }
    }

    /// NFR-11: tap → newest message drawn, 30 times over the first rooms.
    @MainActor
    func test2RoomOpen() throws {
        let app = try requireSignedIn()
        let options = XCTMeasureOptions()
        options.iterationCount = 30
        var index = 0
        measure(metrics: [signpost("room-open")], options: options) {
            openRoom(app, index)
            index += 1
            goBack(app)
        }
    }

    /// NFR-2: scrolling mixed media.
    @MainActor
    func test3Scroll() throws {
        let app = try requireSignedIn()
        openRoom(app, 0, named: env["HALO_PERF_MEDIA_ROOM"])
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTHitchMetric(application: app), XCTMemoryMetric(application: app), signpost("main-thread-hang")], options: options) {
            for _ in 0..<4 { list.swipeDown(velocity: .fast) }
            for _ in 0..<4 { list.swipeUp(velocity: .fast) }
        }
        goBack(app)
    }

    /// NFR-12 and NFR-13: 50 room open/close cycles; what memory grows by, its peak, and main-thread hangs on the way.
    @MainActor
    func test4Cycles() throws {
        let app = try requireSignedIn()
        for index in 0..<6 {  // warm the caches first: the growth of the first visits isn't a leak
            openRoom(app, index)
            goBack(app)
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), signpost("main-thread-hang")], options: options) {
            for index in 0..<25 {  // `measure` runs the block twice
                openRoom(app, index)
                goBack(app)
            }
        }
    }

    /// NFR-15: what a minute of doing nothing in the foreground costs (CPU; battery needs a device and an hour).
    @MainActor
    func test5Idle() throws {
        let app = try requireSignedIn()
        Thread.sleep(forTimeInterval: 15)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app), signpost("main-thread-hang")], options: options) {
            Thread.sleep(forTimeInterval: 60)
        }
    }

    // MARK: Helpers

    private func signpost(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "one.mbm.halo", category: "performance", name: name)
    }

    @MainActor
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        // No first-run sheets over what is measured (the arguments override the app's own preferences for this launch).
        app.launchArguments += ["-HaloMeasureHangs", "YES", "-halo.onboarding.notificationPrimingShown", "YES",
                                "-halo.lastSeenWhatsNewVersion", env["HALO_PERF_VERSION"] ?? ""]
        return app
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = application()
        app.launch()
        return app
    }

    @MainActor @discardableResult
    private func requireSignedIn() throws -> XCUIApplication {
        let app = launch()
        dismissSheets(app, for: 2)
        guard app.buttons["settings"].waitForExistence(timeout: 10) else { throw XCTSkip("The app is signed out.") }
        XCTAssertTrue(rooms(app).firstMatch.waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func rooms(_ app: XCUIApplication) -> XCUIElementQuery {
        app.collectionViews["room-list"].cells.containing(NSPredicate(format: "label != 'Media Gallery'"))
    }

    /// Opens the `index`-th chat (after the Media Gallery entry), or the one called `name` when the list shows it.
    @MainActor
    private func openRoom(_ app: XCUIApplication, _ index: Int, named name: String? = nil) {
        let cells = app.collectionViews.firstMatch.cells
        // An account with fewer chats (scalebig has two) takes turns through those it has.
        var cell = cells.element(boundBy: 1 + index % max(1, min(6, cells.count - 1)))
        if let name {
            let found = cells.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            if found.waitForExistence(timeout: 3) { cell = found }
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "chat \(index)")
        cell.tap()
        XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 15), "The room opened")
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func replaceText(of field: XCUIElement, with text: String) {
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
        }
        field.typeText(text)
    }

    @MainActor
    private func dismissSheets(_ app: XCUIApplication, for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if app.buttons["skip-notifications"].exists { app.buttons["skip-notifications"].tap() }
            else if app.staticTexts["What's New in Halo"].exists { app.buttons["Continue"].tap() }
            else if app.buttons["settings"].exists, app.buttons["settings"].isHittable { return }
            else { Thread.sleep(forTimeInterval: 0.3) }
        }
    }
}
