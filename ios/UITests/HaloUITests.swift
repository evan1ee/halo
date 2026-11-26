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
            // iOS's own hidden "Search" button that belongs to the floating search field (no identifier; on an iPhone 16
            // it sits invisibly mid-list and is measured against nothing). Halo's buttons carry identifiers (D96, amended
            // 2026-11-23 after the iPhone 16 run).
            if issue.auditType == .contrast, glassTop < .infinity, let element = issue.element,
               [.button, .staticText].contains(element.elementType), element.label == "Search", element.identifier.isEmpty {
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

    /// The Chats root screen (identified by the root toolbar's Settings avatar button; the header intentionally has no title).
    @MainActor
    private func chatsRoot(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["settings"]
    }

    @MainActor
    func testLaunchRootScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)

        // The app launches either into SignInView (signed out) or Chats (signed in).
        let signInVisible = app.staticTexts["Halo"].waitForExistence(timeout: 5)
        let chatsVisible = chatsRoot(app).waitForExistence(timeout: 2)
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

        let serverField = app.textFields["Homeserver"]
        if serverField.waitForExistence(timeout: 5) {
            serverField.tap()
            serverField.typeText(server)
            app.buttons["Continue"].tap()
            let userField = app.textFields["Username"]
            XCTAssertTrue(userField.waitForExistence(timeout: 15), "The server offers password sign-in")
            userField.tap()
            userField.typeText(user)
            let passwordField = app.secureTextFields["Password"]
            passwordField.tap()
            passwordField.typeText(password)
            let tapped = Date()
            app.buttons["Sign in"].tap()
            // First run after sign-in may ask about notifications; answer later.
            let skip = app.buttons["skip-notifications"]
            let chatsBar = chatsRoot(app)
            for _ in 0..<60 where !chatsBar.exists {
                if skip.exists { skip.tap() }
                _ = chatsBar.waitForExistence(timeout: 0.5)
            }
            XCTAssertTrue(chatsBar.waitForExistence(timeout: 1))
            let chats = Date().timeIntervalSince(tapped)
            if skip.waitForExistence(timeout: 2) { skip.tap() }
            if app.buttons["focus-show-all"].waitForExistence(timeout: 1) { app.buttons["focus-show-all"].tap() }
            let rowsShown = app.collectionViews.firstMatch.buttons.element(boundBy: 1).waitForExistence(timeout: 60)
            let note = XCTAttachment(string: String(format: "sign-in: Chats after %.2f s, rows %@ after %.2f s", chats,
                rowsShown ? "shown" : "NOT shown", Date().timeIntervalSince(tapped)))
            note.name = "sign-in-timing"
            note.lifetime = .keepAlways
            add(note)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "after-sign-in"
            shot.lifetime = .keepAlways
            add(shot)
        }

        XCTAssertTrue(chatsRoot(app).waitForExistence(timeout: 15))
        try audit(app)
    }

    /// Closes the keyboard or a composer panel by dragging the conversation (COMPOSER_PANELS §3). A tap could land on a
    /// message (a photo opens the full-screen viewer), so the tests drag instead.
    @MainActor
    private func dismissComposerInput(_ app: XCUIApplication) {
        // Like Messages: the keyboard follows a drag that reaches into it (interactive dismissal); a panel closes as soon
        // as the conversation is dragged.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
    }

    /// Skips a test that taps keys when this simulator shows no software keyboard (a hardware keyboard is connected: its keys
    /// exist but lie off screen). `scripts/prepush.sh` turns that hiding off (`AutomaticMinimizationEnabled`). A skip is not a pass.
    @MainActor
    private func requireSoftwareKeyboard(_ app: XCUIApplication) throws {
        // On a physical device, the first key element in accessibility order may be non-hittable while the keyboard
        // is still animating or for auxiliary keys; check whether any software key is hittable after a brief wait.
        _ = app.keys.firstMatch.waitForExistence(timeout: 2)
        let hasHittableKey = app.keys.allElementsBoundByIndex.contains(where: \.isHittable)
        try XCTSkipUnless(hasHittableKey, "No software keyboard: a hardware keyboard is connected to this simulator.")
    }

    /// Back to the chat list. On the iPad the list is the always-visible sidebar, so the first navigation button is its
    /// show/hide toggle, not a back button: tapping it would hide the list.
    @MainActor
    private func returnToChatList(_ app: XCUIApplication) {
        if chatsRoot(app).exists, chatsRoot(app).isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
    }

    /// Opens the first chat (not the Media Gallery) on a signed-in simulator so the composer is shown; skips when signed out.
    @MainActor
    /// A fresh install shows "What's New" and the notifications prompt over the chats; answer both so tests see the app.
    private func dismissFirstRunSheets(_ app: XCUIApplication) {
        for _ in 0..<3 {
            let whatsNew = app.buttons["Continue"]
            let skip = app.buttons["skip-notifications"]
            if whatsNew.waitForExistence(timeout: 1.5), app.staticTexts["What's New in Halo"].exists { whatsNew.tap(); continue }
            if skip.exists { skip.tap(); continue }
            break
        }
    }

    /// Pasting an image into the message field (edit menu or the keyboard's paste suggestion) adds it as a pending photo
    /// and leaves no placeholder in the draft (founder: "Can not sent the paste image").
    @MainActor
    func testPastedImageJoinsPendingPhotos() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        try openFirstChat(app)
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        // On a device the test runner may not be allowed to write the general pasteboard ("not available at this time").
        guard UIPasteboard.general.hasImages else { throw XCTSkip("The test runner can't put an image on this device's pasteboard.") }
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        composer.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3), "The edit menu offers Paste for an image")
        paste.tap()
        let remove = app.buttons["remove-photo"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "The pasted image becomes a pending photo")
        XCTAssertFalse((composer.value as? String ?? "").contains("\u{FFFC}"), "No image placeholder stays in the draft")
        remove.tap()  // nothing is sent
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
        UIPasteboard.general.items = []
    }

    /// Sending a photo: it shows at once, stays on screen through the upload and the server's confirmation (no grey placeholder,
    /// no reload: founder, "image disappears then comes back"), and the spinner gives way to the sent check.
    @MainActor
    func testSentPhotoStaysVisibleAndShowsDeliveryState() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        try openFirstChat(app)
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // The photo is looked for below a message of its own: the images on screen can't be counted, because older ones (every
        // run sends one) scroll off as the new one comes in.
        let marker = "photo check \(UUID().uuidString.prefix(8))"
        composer.tap()
        composer.typeText(marker)
        app.buttons["send-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 10))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 100, y: 100, width: 300, height: 200))
        }
        guard UIPasteboard.general.hasImages else { throw XCTSkip("The test runner can't put an image on this device's pasteboard.") }
        composer.tap()
        composer.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertTrue(app.buttons["remove-photo"].waitForExistence(timeout: 5))
        app.buttons["send-button"].tap()
        // Sample for up to 10 s: once the photo is in the list, it never leaves it.
        var appeared = false, dropped = false, sawConfirmed = false, shots = 0, samples = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 10 {
            if try hasPhoto(below: marker, in: app) { appeared = true } else if appeared { dropped = true }
            if app.descendants(matching: .any)["delivery-sent"].exists || app.descendants(matching: .any)["delivery-read"].exists { sawConfirmed = true }
            samples += 1
            if shots < 16, samples % 2 == 0 {  // a picture of the send flow for the contact sheet
                let a = XCTAttachment(screenshot: app.screenshot()); a.lifetime = .keepAlways; a.name = "send-\(String(format: "%02d", shots))"; add(a); shots += 1
            }
            if sawConfirmed, shots >= 8, Date().timeIntervalSince(start) > 5 { break }
        }
        XCTAssertTrue(appeared, "The sent photo appears in the conversation")
        XCTAssertFalse(dropped, "The photo never leaves the list between the local echo and the confirmed message")
        XCTAssertTrue(sawConfirmed, "A sent message ends on the sent check (or readers' avatars)")
        UIPasteboard.general.items = []
    }

    /// Whether an image is on screen below the message `text`, from one snapshot (rows may change between two queries).
    @MainActor
    private func hasPhoto(below text: String, in app: XCUIApplication) throws -> Bool {
        var markerBottom: CGFloat?, images: [CGRect] = []
        func visit(_ element: any XCUIElementSnapshot) {
            if element.label == "Image" { images.append(element.frame) }
            if element.label.contains(text), element.children.isEmpty || markerBottom == nil { markerBottom = element.frame.maxY }
            element.children.forEach(visit)
        }
        visit(try app.snapshot())
        guard let markerBottom else { return false }
        return images.contains { $0.minY >= markerBottom - 1 }
    }

    @MainActor
    private func openFirstChat(_ app: XCUIApplication) throws {
        if !chatsRoot(app).waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        guard chatsRoot(app).waitForExistence(timeout: 5) else {
            throw XCTSkip("App is signed out; skipping signed-in composer UI check.")
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
            if app.buttons["sticker-button"].waitForExistence(timeout: 8) {
                openedChat = true
                break
            }
            // iPhone: the room covers the list, go back. iPad: the list stays in the sidebar beside the room (and the
            // first bar button there would hide the sidebar), so just try the next row.
            if !cells.firstMatch.isHittable {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                if back.exists { back.tap() }
            }
        }
        guard openedChat else {
            throw XCTSkip("No room with a sticker button found on this simulator.")
        }
    }

    /// Founder report (2026-11-23): a signed-in launch waited on a loading screen instead of opening on the chats like
    /// Element X. Measures a cold launch to the first chat row (the stored session is restored without network discovery).
    @MainActor
    func testSignedInLaunchOpensOnChats() throws {
        let app = XCUIApplication()
        app.terminate()
        let started = Date()
        app.launch()
        dismissFirstRunSheets(app)
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        let chatsShown = Date().timeIntervalSince(started)
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }
        let firstRow = app.collectionViews.firstMatch.buttons.element(boundBy: 1)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "The cached chats show without waiting for the network")
        let rowsShown = Date().timeIntervalSince(started)
        let labels = app.collectionViews.firstMatch.buttons.allElementsBoundByIndex.prefix(5).map(\.label)
        let note = XCTAttachment(string: String(format: "Chats bar after %.2f s, first rows after %.2f s\n", chatsShown, rowsShown)
            + labels.joined(separator: "\n"))
        note.name = "launch-to-chats"
        note.lifetime = .keepAlways
        add(note)
        // XCUITest's launch waits for the app to go idle, which adds seconds of its own (in-app: about 0.3 s on an iPhone 16).
        XCTAssertLessThan(rowsShown, 15, "A signed-in launch reaches the chat list without waiting on the network")
    }

    /// Diagnostic: attaches to Halo as it is on screen (no relaunch), records what it shows and whether it still answers.
    /// Run with `-only-testing:HaloUITests/HaloUITests/testInspectRunningApp` after putting the app in the state to check.
    @MainActor
    func testInspectRunningApp() throws {
        let app = XCUIApplication()
        let started = Date()
        app.activate()
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "running-app-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let snapshotTime = Date().timeIntervalSince(started)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "running-app"
        shot.lifetime = .keepAlways
        add(shot)
        var notes = [String(format: "snapshot after %.2f s", snapshotTime)]
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        if composer.exists {
            let tapped = Date()
            composer.tap()
            let keyboard = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            notes.append(String(format: "keyboard %@ after %.2f s", keyboard ? "shown" : "NOT shown", Date().timeIntervalSince(tapped)))
            let after = XCTAttachment(screenshot: app.screenshot())
            after.name = "running-app-keyboard"
            after.lifetime = .keepAlways
            add(after)
        }
        let note = XCTAttachment(string: notes.joined(separator: "\n"))
        note.name = "running-app-notes"
        note.lifetime = .keepAlways
        add(note)
    }

    /// Founder report (2026-11-23): opening a room without messages froze the app (seen in a room whose only event
    /// is the join). Opens the chats named "Empty…" (rooms without messages; `create-fixtures.py` makes one) and checks each shows
    /// its empty state and stays responsive.
    @MainActor
    func testEmptyRoomStaysResponsive() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) {
            returnToChatList(app)
        }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }
        let rows = app.collectionViews.firstMatch.cells.containing(NSPredicate(format: "label BEGINSWITH[c] 'empty'"))
        let emptyRow = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'empty'"))
        guard emptyRow.firstMatch.waitForExistence(timeout: 5) || rows.firstMatch.exists else { throw XCTSkip("No empty room on this account.") }
        // Names first: the list re-sorts while rooms are visited, so rows are found by name, not position.
        let names = emptyRow.allElementsBoundByIndex.map { String($0.label.split(separator: ",").first ?? "") }
        let wanted = Array(names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(5))
        for (index, name) in wanted.enumerated() {
            let row = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
            guard row.waitForExistence(timeout: 5) else { XCTFail("\(name): row not found"); continue }
            let opened = Date()
            row.tap()
            let composer = app.descendants(matching: .any)["composer"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 5), "\(name): the composer shows")
            let emptyState = app.descendants(matching: .any)["empty-room"].firstMatch.waitForExistence(timeout: 5)
            let note = XCTAttachment(string: String(format: "%@ opened in %.2f s", name, Date().timeIntervalSince(opened)))
            note.name = "empty-room-open"
            note.lifetime = .keepAlways
            add(note)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "empty-room-\(index)"
            shot.lifetime = .keepAlways
            add(shot)
            // Test data can gain messages (another run may post into these rooms); the empty state is checked only
            // while the room has no message rows. Responsiveness below is checked either way.
            let hasMessages = app.staticTexts["Waiting for this message's key"].exists
                || app.descendants(matching: .any).matching(identifier: "message-row").firstMatch.exists
                || app.images.firstMatch.exists  // photos (other tests post some into this room)
            if !hasMessages { XCTAssertTrue(emptyState, "\(name): an empty room says so instead of a blank list") }
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "\(name): the keyboard opens")
            try requireSoftwareKeyboard(app)
            // Real key taps (XCUIElement.typeText may touch the screen, which a person typing doesn't).
            app.keys.matching(NSPredicate(format: "label ==[c] 'h'")).firstMatch.tap()
            app.keys.matching(NSPredicate(format: "label ==[c] 'i'")).firstMatch.tap()
            app.buttons["sticker-button"].tap()
            XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForExistence(timeout: 3), "\(name): the emoji panel opens")
            app.buttons["panel-tab-emoji"].tap()
            XCTAssertTrue(app.buttons["emoji-delete"].waitForExistence(timeout: 3))
            app.buttons["emoji-delete"].tap()
            app.buttons["emoji-delete"].tap()
            returnToChatList(app)
            XCTAssertTrue(chatsRoot(app).waitForExistence(timeout: 5), "\(name): back to the chat list")
        }
    }

    /// Message search (MESSAGE_SEARCH §5): filters and the coverage notice, a hit opens its chat at the message, back to the newest.
    @MainActor
    func testMessageSearchOpensAHit() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        guard chatsRoot(app).waitForExistence(timeout: 15) else { throw XCTSkip("App is signed out.") }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("e")
        XCTAssertTrue(app.buttons["search-filter-files"].waitForExistence(timeout: 5), "Filters show with a query")
        let hits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-hit-'"))
        guard hits.firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("No message with an e on this account yet.") }
        app.buttons["search-filter-files"].tap()
        XCTAssertTrue(app.buttons["search-filter-files"].isSelected)
        app.buttons["search-filter-all"].tap()
        XCTAssertTrue(hits.firstMatch.waitForExistence(timeout: 10))
        hits.element(boundBy: min(3, hits.count - 1)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline"].waitForExistence(timeout: 10), "The hit opens its chat")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3), "The message is found")
    }

    /// M4/M5 simulator UI check: opens a chat, verifies the sticker panel loads packs/stickers, and exercises New pack creation.
    @MainActor
    func testStickerPanelAndPackCreationFlow() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)

        try openFirstChat(app)

        // The expression panel remembers its last tab and sticker source: pick Stickers → My stickers.
        app.buttons["sticker-button"].tap()
        if app.buttons["panel-tab-stickers"].waitForExistence(timeout: 3) { app.buttons["panel-tab-stickers"].tap() }
        if app.buttons["My stickers"].exists { app.buttons["My stickers"].tap() }
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
        dismissComposerInput(app)
        _ = search.waitForNonExistence(timeout: 3)
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        returnToChatList(app)
        XCTAssertTrue(chatsRoot(app).waitForExistence(timeout: 5), "Should return to Chats root")
    }

    /// Cold-launch performance metric (ROADMAP M15, SR-06, NFR-1).
    /// Opt-in via `HALO_RUN_PERF_TESTS=1` so routine `prepush.sh` runs stay fast.
    /// COMPOSER_PANELS (D97/D98) simulator check: the expression panel opens in place of the keyboard, switches tabs,
    /// inserts an emoji, swaps back to the keyboard, and the attachment panel shows its actions. Nothing is sent.
    @MainActor
    func testComposerPanelsSwapWithKeyboard() throws {
        let app = XCUIApplication()
        // Forget the remembered keyboard height: the first panel must still match the keyboard it later swaps with.
        app.launchArguments += ["-halo.composer.keyboardOverlaps", "{}", "-halo.debug.composerTrace", "YES"]
        app.launch()
        dismissFirstRunSheets(app)
        try openFirstChat(app)
        // Frame-by-frame position of the message field as drawn (presentation layer), from `ComposerMotionTrace`.
        var frameDrifts: [String: Double] = [:]
        func recordFrameDrift(_ label: String) {
            let trace = app.descendants(matching: .any)["composer-trace"].firstMatch
            guard trace.exists, let text = trace.value as? String else { return }
            let ys = text.split(separator: ",").compactMap { Double($0) }
            guard let settled = ys.last else { return }
            let drift = ys.map { abs($0 - settled) }.max() ?? 0
            frameDrifts[label] = drift
            let note = XCTAttachment(string: "frames \(label): drift \(String(format: "%.1f", drift)) pt over \(ys.count) frames: " + text)
            note.name = "composer-frames-\(label)"
            note.lifetime = .keepAlways
            add(note)
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // A draft left by an earlier run: clear it all so the steps below start from an empty field.
        if let draft = composer.value as? String, !draft.isEmpty, draft != "Message" {
            // Tap the field's bottom-right corner so the cursor lands at the end (a tap may leave it at the start, and
            // deleting from there removes nothing); then delete backwards past everything.
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
            // Hold the keyboard's delete key (it speeds up to whole words) until the field is empty; the value is truncated,
            // and a long typeText of deletes stops early.
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            try requireSoftwareKeyboard(app)
            for _ in 0..<8 {
                let value = composer.value as? String ?? ""
                if value.isEmpty || value == "Message" { break }
                app.keys["delete"].press(forDuration: 3)
            }
            XCTAssertTrue(((composer.value as? String) ?? "").isEmpty || composer.value as? String == "Message", "The leftover draft is cleared")
            dismissComposerInput(app)
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
            _ = app.staticTexts["settle"].waitForExistence(timeout: 1.5)
        }
        let attach = app.buttons["attachment-button"]
        /// Samples the composer row's top edge right after `action`, while the keyboard/panel swap animates, and records them.
        func sampleComposerTop(_ label: String, during action: () -> Void) -> [Double] {
            action()
            recordFrameDrift(label)
            var samples: [Double] = []
            for _ in 0..<12 { samples.append(Double(attach.frame.minY)) }
            let note = XCTAttachment(string: "\(label): " + samples.map { String(format: "%.1f", $0) }.joined(separator: ", "))
            note.name = "composer-y-\(label)"
            note.lifetime = .keepAlways
            add(note)
            return samples
        }

        // Founder's flow: face icon first (no keyboard seen yet in this room), insert an emoji, then the keyboard icon.
        // The message field must stay where it is.
        app.buttons["sticker-button"].tap()
        XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForExistence(timeout: 3))
        // Emoji · GIFs · Stickers (the panel opens on Emoji the first time, then on the last tab used).
        app.buttons["panel-tab-emoji"].tap()
        XCTAssertTrue(app.buttons["panel-tab-emoji"].isSelected)
        if app.buttons["panel-tab-gifs"].exists, app.buttons["panel-tab-stickers"].exists {
            XCTAssertLessThan(app.buttons["panel-tab-emoji"].frame.minX, app.buttons["panel-tab-gifs"].frame.minX)
            XCTAssertLessThan(app.buttons["panel-tab-gifs"].frame.minX, app.buttons["panel-tab-stickers"].frame.minX)
        }
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        let firstPanelTop = Double(attach.frame.minY)
        let anyEmoji = app.buttons.matching(identifier: "grinning").firstMatch.exists
            ? app.buttons.matching(identifier: "grinning").firstMatch : app.buttons["grinning face"].firstMatch
        if anyEmoji.waitForExistence(timeout: 2) { anyEmoji.tap() }
        let firstSwap = sampleComposerTop("first-panel-to-keyboard") { app.buttons["sticker-button"].tap() }
        shot("0-first-swap")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // With a hardware keyboard connected the simulator shows no software keyboard (only a thin shortcut bar, or an
        // off-screen keyboard frame whose keys aren't hittable), so there is no keyboard height to match: skip instead of
        // failing (I/O → Keyboard → Connect Hardware Keyboard, ⇧⌘K).
        try XCTSkipIf(app.keyboards.firstMatch.frame.height < 150, "No software keyboard: a hardware keyboard is connected to this simulator.")
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        try requireSoftwareKeyboard(app)
        let firstKeyboardTop = Double(attach.frame.minY)
        let firstNote = XCTAttachment(string: String(format: "first open: panel %.1f, keyboard %.1f, samples %@", firstPanelTop, firstKeyboardTop,
            firstSwap.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        firstNote.name = "composer-y-first-open"
        firstNote.lifetime = .keepAlways
        add(firstNote)
        XCTAssertEqual(firstKeyboardTop, firstPanelTop, accuracy: 2, "Face icon → emoji → keyboard must not move the message field")
        dismissComposerInput(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        // XCUITest aims at the final frame while the composer is still sliding down; let it settle before the next tap.
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1.5)

        // The keyboard alone, from nothing and back: the system moves the composer with the keyboard (frames recorded).
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        recordFrameDrift("idle-to-keyboard")
        dismissComposerInput(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1.5)
        recordFrameDrift("keyboard-to-idle")

        // Expression panel: opens without the keyboard, with its tab pill.
        app.buttons["sticker-button"].tap()
        XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForExistence(timeout: 3), "Expression panel should show its tabs")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The panel replaces the keyboard")
        shot("1-expression-panel")

        // Emoji tab: search and insert.
        app.buttons["panel-tab-emoji"].tap()
        // Start from an empty draft (an earlier run may have left one).
        for _ in 0..<20 where !(composer.value as? String ?? "").isEmpty && (composer.value as? String) != "Message" {
            app.buttons["emoji-delete"].tap()
        }
        let emojiSearch = app.textFields["emoji-search"]
        XCTAssertTrue(emojiSearch.waitForExistence(timeout: 3))
        shot("2-emoji-tab")
        emojiSearch.tap()
        emojiSearch.typeText("pizza")
        let pizza = app.buttons["pizza"]
        XCTAssertTrue(pizza.waitForExistence(timeout: 3), "Search should find the pizza emoji")
        shot("3-emoji-search")
        pizza.tap()
        XCTAssertTrue((composer.value as? String ?? "").contains("🍕"), "Tapping an emoji inserts it into the draft")

        // Tapping the field swaps the panel for the keyboard.
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForNonExistence(timeout: 3), "The keyboard replaces the panel")
        // Typing keeps the keyboard up (the send button appearing in the field must not cost the field its focus).
        // Real key taps on the keyboard, like a person (XCUIElement.typeText may touch the element first).
        app.keys.matching(NSPredicate(format: "label ==[c] 'o'")).firstMatch.tap()
        app.keys.matching(NSPredicate(format: "label ==[c] 'k'")).firstMatch.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForNonExistence(timeout: 1.5), "Typing keeps the keyboard up")
        // Autocorrect may have changed what was typed ("Ok"): delete until the letters are gone, the emoji stays.
        for _ in 0..<6 where (composer.value as? String ?? "").lowercased().contains(where: { $0 == "o" || $0 == "k" }) {
            app.keys["delete"].tap()
        }
        shot("4-keyboard")
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        let keyboardTop = Double(attach.frame.minY)

        // AC-CP1: keyboard → panel → keyboard keeps the composer where it is, during and after each swap.
        let toPanel = sampleComposerTop("keyboard-to-panel") { app.buttons["sticker-button"].tap() }
        XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForExistence(timeout: 3))
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        let panelTop = Double(attach.frame.minY)
        let toKeyboard = sampleComposerTop("panel-to-keyboard") { app.buttons["sticker-button"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        let summary = XCTAttachment(string: String(format: "settled keyboard %.1f, panel %.1f, back %.1f; max drift during swaps %.1f pt",
            keyboardTop, panelTop, Double(attach.frame.minY),
            (toPanel + toKeyboard).map { abs($0 - keyboardTop) }.max() ?? 0))
        summary.name = "composer-y-summary"
        summary.lifetime = .keepAlways
        add(summary)
        XCTAssertEqual(panelTop, keyboardTop, accuracy: 2, "The panel puts the composer where the keyboard did")
        XCTAssertEqual(Double(attach.frame.minY), keyboardTop, accuracy: 2, "Back to the keyboard, the composer returns to the same place")

        // The toggle swaps back to the panel; its delete key removes the emoji again (the draft is left empty).
        app.buttons["sticker-button"].tap()
        XCTAssertTrue(app.buttons["panel-tab-emoji"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["emoji-delete"].waitForExistence(timeout: 3))
        app.buttons["emoji-delete"].tap()
        XCTAssertFalse((composer.value as? String ?? "").contains("🍕"), "The panel's delete key removes the last emoji")

        // ↑ pulls the panel up to a tall sheet, ↓ brings it back to the same place (smoothly, no flash).
        let expand = app.buttons["panel-expand-button"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "With a panel open the right button expands it")
        XCTAssertEqual(expand.label, "Expand panel")
        let normalTop = Double(attach.frame.minY)
        let growing = sampleComposerTop("expand") { expand.tap() }
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        let expandedTop = Double(attach.frame.minY)
        XCTAssertLessThan(expandedTop, normalTop - 150, "The expanded panel lifts the composer well up")
        XCTAssertEqual(expand.label, "Shrink panel")
        shot("4b-expanded")
        let shrinking = sampleComposerTop("collapse") { expand.tap() }
        _ = app.staticTexts["settle"].waitForExistence(timeout: 1)
        XCTAssertEqual(Double(attach.frame.minY), normalTop, accuracy: 2, "Collapsing returns the panel to its height")
        XCTAssertTrue((growing + shrinking).allSatisfy { $0 >= expandedTop - 2 && $0 <= normalTop + 2 }, "No overshoot or flash while resizing")

        // GIFs (KLIPY) when the build has a key.
        if app.buttons["panel-tab-gifs"].exists {
            app.buttons["panel-tab-gifs"].tap()
            XCTAssertTrue(app.textFields["gif-search"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.textFields["gif-search"].placeholderValue, "Search KLIPY")
            XCTAssertTrue(app.staticTexts["TRENDING"].waitForExistence(timeout: 30), "KLIPY trending should load")
            _ = app.staticTexts["media-settle"].waitForExistence(timeout: 12)  // gives the previews time to arrive
            shot("5-gifs")
        }

        // Attachment panel.
        app.buttons["attachment-button"].tap()
        XCTAssertTrue(app.buttons["attach-tab-gallery"].waitForExistence(timeout: 3), "Attachment panel should show its tabs")
        _ = app.staticTexts["photos-settle"].waitForExistence(timeout: 3)
        shot("6-attachments")
        // Gallery · File · Location · Poll (D100).
        app.buttons["attach-tab-file"].tap()
        XCTAssertTrue(app.buttons["file-button"].waitForExistence(timeout: 3), "File tab offers Files")
        shot("6b-file")
        app.buttons["attach-tab-poll"].tap()
        XCTAssertTrue(app.buttons["create-poll-button"].waitForExistence(timeout: 3))
        app.buttons["create-poll-button"].tap()
        let question = app.textViews["poll-question"].exists ? app.textViews["poll-question"] : app.textFields["poll-question"]
        XCTAssertTrue(question.waitForExistence(timeout: 3), "The poll form opens")
        XCTAssertFalse(app.buttons["poll-send"].isEnabled, "An empty poll can't be sent")
        question.tap()
        question.typeText("Lunch?")
        app.textFields["poll-answer-0"].tap()
        app.textFields["poll-answer-0"].typeText("Pizza")
        app.textFields["poll-answer-1"].tap()
        app.textFields["poll-answer-1"].typeText("Sushi")
        XCTAssertTrue(app.buttons["poll-send"].isEnabled, "A question with two answers can be sent")
        shot("6c-poll")
        app.buttons["Cancel"].tap()  // nothing is sent
        XCTAssertTrue(question.waitForNonExistence(timeout: 3))
        // Article (D101): Markdown editor with a formatting bar and a preview; closing keeps the draft.
        app.buttons["attach-tab-article"].tap()
        XCTAssertTrue(app.buttons["write-article-button"].waitForExistence(timeout: 3))
        app.buttons["write-article-button"].tap()
        let articleEditor = app.textViews["article-editor"]
        XCTAssertTrue(articleEditor.waitForExistence(timeout: 3), "The article editor opens")
        XCTAssertFalse(app.buttons["article-send"].isEnabled, "An empty article can't be sent")
        articleEditor.tap()
        app.buttons["article-format-heading"].tap()
        articleEditor.typeText("Weekly notes\n")
        app.buttons["article-format-bulletList"].tap()
        articleEditor.typeText("first ")
        app.buttons["article-format-bold"].tap()
        articleEditor.typeText("item")
        // Prefixes and markers from the bar (a device keyboard's autocorrect may change the typed words themselves).
        let article = articleEditor.value as? String ?? ""
        XCTAssertTrue(article.hasPrefix("## ") && article.contains("\n- ") && article.contains("**"), "The formatting bar writes Markdown: \(article)")
        XCTAssertTrue(app.buttons["article-send"].isEnabled)
        shot("6d-article-write")
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.staticTexts["Weekly notes"].waitForExistence(timeout: 3), "The preview draws the heading")
        shot("6e-article-preview")
        app.buttons["article-close"].tap()  // nothing is sent
        XCTAssertTrue(articleEditor.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["write-article-button"].label, "Continue article", "Closing keeps the article")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.buttons["attach-tab-location"].tap()
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["send-pinned-location"].waitForExistence(timeout: 5), "Location tab offers the pinned place")
        _ = app.staticTexts["map-settle"].waitForExistence(timeout: 3)
        shot("6d-location")

        // A tap on the conversation closes the panel.
        dismissComposerInput(app)
        XCTAssertTrue(app.buttons["file-button"].waitForNonExistence(timeout: 3))
        shot("7-closed")
        XCTAssertTrue(app.buttons["voice-button"].waitForExistence(timeout: 3), "An empty field with nothing open offers the mic")

        // A KLIPY GIF already in this room plays inline (loaded straight from KLIPY, D98).
        let klipyMessage = app.descendants(matching: .any)["klipy-message-media"].firstMatch
        if klipyMessage.waitForExistence(timeout: 3) {
            let loaded = NSPredicate(format: "value == 'loaded'")
            XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: loaded, evaluatedWith: klipyMessage)], timeout: 60), .completed,
                "The KLIPY message should load and play, not fall back")
            shot("8-klipy-message")
        }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
    }

    /// The app's performance signposts (LOGGING_AND_DIAGNOSTICS §5) reach XCTest from a real launch, sync and room open. Values aren't
    /// judged here: a simulator shows trends only (TEST_STRATEGY §7).
    @MainActor
    func testPerformanceSignpostsAreRecorded() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        app.terminate()

        let intervals = ["cold-start", "sync-catch-up", "room-open"]
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        SignpostReader.durations = [:]
        var opened: (any Error)?
        measure(metrics: intervals.map { SignpostReader(subsystem: "one.mbm.halo", category: "performance", name: $0) }, options: options) {
            app.launch()
            do { try openFirstChat(app) } catch { opened = error }
            returnToChatList(app)
            app.terminate()
        }
        if let opened { throw opened }
        for interval in intervals {
            let values = SignpostReader.durations[interval] ?? []
            XCTAssertFalse(values.isEmpty, "no \(interval) interval was recorded")
            for value in values { XCTAssertTrue((0.001..<30).contains(value), "\(interval) took \(value) s") }
        }
    }

    /// A launch shows the chat list, not the room (or page) that was open when the app was closed (founder, 2026-11-26).
    @MainActor
    func testLaunchShowsChatsNotTheLastRoom() throws {
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        try openFirstChat(app)
        XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 8), "a room is open")
        app.terminate()
        app.launch()
        XCTAssertTrue(chatsRoot(app).waitForExistence(timeout: 15), "the launch lands on the chat list")
        XCTAssertFalse(app.buttons["sticker-button"].exists, "no room is open after the launch")
    }

    /// One transition of the zero flash and jump audit (ROADMAP M19-9, AC-MOT-1), filmed from outside by `scripts/motion_audit.py`, which
    /// sets `HALO_MOTION_SCENARIO`. Every scenario holds still for a moment before and after, so the film shows the rest state too.
    @MainActor
    func testMotionAudit() throws {
        guard let scenario = ProcessInfo.processInfo.environment["HALO_MOTION_SCENARIO"] else {
            throw XCTSkip("Run through scripts/motion_audit.py.")
        }
        func hold(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
        // The film also holds the test runner starting and the app launching: these two times say which part is the scenario.
        let marks = ProcessInfo.processInfo.environment["HALO_MOTION_MARKS"]
        func mark(_ name: String) {
            guard let marks else { return }
            let line = "\(name) \(Date().timeIntervalSince1970)\n"
            if let handle = FileHandle(forWritingAtPath: marks) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile() }
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 4) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 15) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }
        hold(2)
        mark("begin")
        defer { mark("end") }
        switch scenario {
        case "launch":
            app.terminate()
            hold(1)
            app.launch()
            _ = chatsRoot(app).waitForExistence(timeout: 15)
            hold(3)
        case "room-open-close":
            try openFirstChat(app)
            hold(2)
            returnToChatList(app)
            hold(2)
            try openFirstChat(app)
            hold(2)
            returnToChatList(app)
            hold(2)
        case "room-open-other":
            // A room below the top three of the chat list (M19-9, D-MOT-2): the fifth chat row, opened twice.
            let row = app.collectionViews.firstMatch.cells.element(boundBy: 5)
            guard row.waitForExistence(timeout: 5) else { throw XCTSkip("Fewer than five chats.") }
            for _ in 0..<2 {
                row.tap()
                XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 8), "the room opened")
                hold(2)
                returnToChatList(app)
                hold(2)
            }
            hold(3)  // the film's window is matched to the marks only roughly: keep the last close inside it
        case "keyboard":
            try openFirstChat(app)
            hold(2)
            app.descendants(matching: .any)["composer"].firstMatch.tap()
            hold(2.5)
            app.descendants(matching: .any)["timeline"].firstMatch.swipeDown(velocity: .slow)
            hold(2.5)
        case "send":
            try openFirstChat(app)
            hold(2)
            let composer = app.descendants(matching: .any)["composer"].firstMatch
            composer.tap()
            hold(1.5)
            composer.typeText("motion audit \(Int(Date().timeIntervalSince1970) % 1000)")
            hold(1)
            app.buttons["send-button"].tap()
            hold(5)
        case "reaction":
            try openFirstChat(app)
            hold(2)
            let message = app.descendants(matching: .any)["timeline"].firstMatch.staticTexts.element(boundBy: 2)
            message.doubleTap()
            hold(4)
        case "appearance":
            try openFirstChat(app)
            hold(2)
            // The script switches the simulator (`xcrun simctl ui … appearance`) when it sees these marks: the runner's own
            // `XCUIDevice.appearance` did not change what the film shows.
            mark("dark")
            hold(4)
            mark("light")
            hold(4)
        case "background":
            try openFirstChat(app)
            hold(2)
            XCUIDevice.shared.press(.home)
            hold(4)
            app.activate()
            hold(3.5)
        case "scroll-up":
            try openFirstChat(app)
            hold(2)
            let timeline = app.descendants(matching: .any)["timeline"].firstMatch
            timeline.swipeDown(velocity: .fast)
            hold(1)
            timeline.swipeDown(velocity: .fast)
            hold(3)
        default:
            XCTFail("unknown scenario \(scenario)")
        }
    }

    /// Physical-device D95 check: open S10 (or the first non-gallery room) 10 times; each open must land at the newest
    /// message (no `jump-to-bottom` button, no lingering loading spinner). Opt-in via `HALO_RUN_DEVICE_CHECKS=1`.
    @MainActor
    func testRoomOpeningLandsAtNewestTenTimes() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_DEVICE_CHECKS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_DEVICE_CHECKS=1 to run physical-device D95 room-opening check.")
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }

        let s10 = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'S10'")).firstMatch
        let hasS10 = s10.waitForExistence(timeout: 5)
        for attempt in 1...10 {
            if hasS10 {
                XCTAssertTrue(s10.waitForExistence(timeout: 5), "Run \(attempt): S10 row should exist")
                s10.tap()
                XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 8), "Run \(attempt): S10 should open")
            } else {
                try openFirstChat(app)
            }
            _ = app.staticTexts["settle"].waitForExistence(timeout: 0.6)
            XCTAssertFalse(app.staticTexts["Loading messages…"].exists, "Run \(attempt): no loading spinner after room open")
            XCTAssertFalse(
                app.buttons["jump-to-bottom"].exists,
                "Run \(attempt): room must land at the newest message (jump-to-bottom must not appear)"
            )
            if attempt == 1 || attempt == 10 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "d95-open-\(String(format: "%02d", attempt))"
                shot.lifetime = .keepAlways
                add(shot)
            }
            returnToChatList(app)
            XCTAssertTrue(chatsRoot(app).waitForExistence(timeout: 5), "Run \(attempt): back to Chats root")
        }
    }

    /// Physical-device live-send check (HANDOFF §5): sends a pinned location, a poll, a Markdown article, and a KLIPY GIF
    /// into S10 (or the first non-gallery room) and verifies each renders in the timeline. Opt-in via `HALO_RUN_DEVICE_CHECKS=1`.
    @MainActor
    func testLiveSendsLocationPollArticleAndKlipy() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_DEVICE_CHECKS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_DEVICE_CHECKS=1 to run physical-device live-send checks.")
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }

        let s10 = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'S10'")).firstMatch
        if s10.waitForExistence(timeout: 5) {
            s10.tap()
            XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 8), "Expected timeline composer in S10")
        } else {
            try openFirstChat(app)
        }

        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // 1. Live send: pinned location.
        app.buttons["attachment-button"].tap()
        XCTAssertTrue(app.buttons["attach-tab-location"].waitForExistence(timeout: 5))
        app.buttons["attach-tab-location"].tap()
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let sendPin = app.buttons["send-pinned-location"]
        XCTAssertTrue(sendPin.waitForExistence(timeout: 8), "Location tab should offer send-pinned-location")
        sendPin.tap()
        XCTAssertTrue(sendPin.waitForNonExistence(timeout: 5), "Location panel should dismiss after sending")
        _ = app.staticTexts["settle"].waitForExistence(timeout: 2)
        shot("live-1-location")

        // 2. Live send: poll.
        let pollQuestionText = "Device poll \(stamp)?"
        app.buttons["attachment-button"].tap()
        XCTAssertTrue(app.buttons["attach-tab-poll"].waitForExistence(timeout: 5))
        app.buttons["attach-tab-poll"].tap()
        XCTAssertTrue(app.buttons["create-poll-button"].waitForExistence(timeout: 5))
        app.buttons["create-poll-button"].tap()
        let question = app.textViews["poll-question"].exists ? app.textViews["poll-question"] : app.textFields["poll-question"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText(pollQuestionText)
        app.textFields["poll-answer-0"].tap()
        app.textFields["poll-answer-0"].typeText("Pizza")
        app.textFields["poll-answer-1"].tap()
        app.textFields["poll-answer-1"].typeText("Sushi")
        XCTAssertTrue(app.buttons["poll-send"].isEnabled)
        app.buttons["poll-send"].tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 8), "Poll sheet should dismiss after sending")
        let pollRendered = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", pollQuestionText)).firstMatch
        XCTAssertTrue(pollRendered.waitForExistence(timeout: 15), "Sent poll should render in the timeline")
        shot("live-2-poll")

        // 3. Live send: Markdown article.
        let articleHeading = "Device Article \(stamp)"
        app.buttons["attachment-button"].tap()
        XCTAssertTrue(app.buttons["attach-tab-article"].waitForExistence(timeout: 5))
        app.buttons["attach-tab-article"].tap()
        XCTAssertTrue(app.buttons["write-article-button"].waitForExistence(timeout: 5))
        app.buttons["write-article-button"].tap()
        let articleEditor = app.textViews["article-editor"]
        XCTAssertTrue(articleEditor.waitForExistence(timeout: 5))
        articleEditor.tap()
        articleEditor.typeText("\n## \(articleHeading)\n\n- **Bold** item\n")
        XCTAssertTrue(app.buttons["article-send"].isEnabled)
        app.buttons["article-send"].tap()
        XCTAssertTrue(articleEditor.waitForNonExistence(timeout: 8), "Article sheet should dismiss after sending")
        let articleRendered = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", articleHeading)).firstMatch
        XCTAssertTrue(articleRendered.waitForExistence(timeout: 15), "Sent article should render in the timeline")
        shot("live-3-article")

        // 4. Live send: KLIPY GIF (when build has a KLIPY key).
        app.buttons["sticker-button"].tap()
        if app.buttons["panel-tab-gifs"].waitForExistence(timeout: 5) {
            app.buttons["panel-tab-gifs"].tap()
            XCTAssertTrue(app.staticTexts["TRENDING"].waitForExistence(timeout: 30), "KLIPY trending should load")
            let firstGif = app.buttons["klipy-gif-item"].firstMatch
            XCTAssertTrue(firstGif.waitForExistence(timeout: 10), "At least one KLIPY GIF item should appear")
            firstGif.tap()
            dismissComposerInput(app)
            let klipyMedia = app.descendants(matching: .any)["klipy-message-media"].firstMatch
            XCTAssertTrue(klipyMedia.waitForExistence(timeout: 15), "Sent KLIPY GIF should appear in the timeline")
            let loaded = NSPredicate(format: "value == 'loaded'")
            XCTAssertEqual(
                XCTWaiter().wait(for: [expectation(for: loaded, evaluatedWith: klipyMedia)], timeout: 45),
                .completed,
                "KLIPY GIF message should load and play inline"
            )
            shot("live-4-klipy")
        }

        returnToChatList(app)
    }

    /// Physical-device verification of timeline scrolling over images and tapping `jump-to-bottom` mid-scroll.
    /// Opt-in via `HALO_RUN_DEVICE_CHECKS=1`.
    @MainActor
    func testTimelineImageScrollAndJumpToBottomWhileScrolling() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_DEVICE_CHECKS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_DEVICE_CHECKS=1 to run physical-device scroll verification.")
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }

        let s10 = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'S10'")).firstMatch
        if s10.waitForExistence(timeout: 5) {
            s10.tap()
            XCTAssertTrue(app.buttons["sticker-button"].waitForExistence(timeout: 8), "Expected timeline composer in S10")
        } else {
            try openFirstChat(app)
        }

        let timeline = app.collectionViews["timeline"].exists ? app.collectionViews["timeline"] : app.collectionViews.firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Expected timeline collection view")

        // 1. Find a visible image in the timeline (scroll up slightly if the newest messages are text/GIF/location).
        let imageButtons = timeline.buttons.matching(NSPredicate(format: "label == 'Image'"))
        var targetImage: XCUIElement?
        for _ in 0..<5 {
            if let visible = imageButtons.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable && $0.frame.height > 40 }) {
                targetImage = visible
                break
            }
            timeline.swipeDown(velocity: .default)
        }
        if let image = targetImage {
            let startFrame = image.frame
            let startCoord = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let endCoord = startCoord.withOffset(CGVector(dx: 0, dy: 260))
            startCoord.press(forDuration: 0.02, thenDragTo: endCoord)
            // Dragging on an image must scroll the list and must NOT open the full-screen photo viewer.
            XCTAssertTrue(app.buttons["sticker-button"].exists, "Dragging on an image must not open the photo viewer")
            let moved = !image.exists || abs(image.frame.midY - startFrame.midY) > 40 || app.buttons["jump-to-bottom"].exists
            XCTAssertTrue(moved, "Dragging vertically starting on an image must scroll the conversation")
        }

        // 2. Fling up fast so the list is actively decelerating, then IMMEDIATELY tap jump-to-bottom without waiting.
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        let jumpDown = app.buttons["jump-to-bottom"]
        XCTAssertTrue(jumpDown.waitForExistence(timeout: 3), "Expected jump-to-bottom button after scrolling up")
        // Trigger a fresh fast fling and immediately tap jump-to-bottom while decelerating.
        timeline.swipeDown(velocity: .fast)
        jumpDown.tap()
        XCTAssertTrue(
            jumpDown.waitForNonExistence(timeout: 4),
            "Tapping jump-to-bottom during ongoing deceleration must interrupt scrolling and return to bottom"
        )

        returnToChatList(app)
    }

    /// Physical-device verification that tapping the room avatar pushes Room info as a navigation page (not a sheet).
    /// Opt-in via `HALO_RUN_DEVICE_CHECKS=1`.
    @MainActor
    func testRoomInfoOpensAsPushedPage() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_DEVICE_CHECKS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_DEVICE_CHECKS=1 to run physical-device Room info verification.")
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }

        try openFirstChat(app)
        let roomInfoButton = app.buttons["roomInfo"]
        XCTAssertTrue(roomInfoButton.waitForExistence(timeout: 5), "Expected roomInfo avatar button in timeline")
        roomInfoButton.tap()

        // Verify pushed page appears with a transparent navigation bar (no title) and a Back button (not a modal sheet).
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 5), "Expected navigation bar on pushed Room info page")
        XCTAssertTrue(app.buttons["roomMediaGallery"].waitForExistence(timeout: 5), "Expected Room info content")
        XCTAssertTrue(navBar.buttons.firstMatch.exists, "Expected native Back button on pushed Room info page")
        XCTAssertTrue(app.sheets.count == 0, "Room info must not be presented as a sheet")

        // Scroll down and verify the list stays clipped below the navigation bar header.
        let list = app.collectionViews.firstMatch
        if list.exists {
            list.swipeUp(velocity: .default)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "room-info-scrolled"
        shot.lifetime = .keepAlways
        add(shot)

        // Tap Back and verify we return cleanly to the timeline (not popped out to Chats).
        navBar.buttons.firstMatch.tap()
        XCTAssertTrue(roomInfoButton.waitForExistence(timeout: 5), "Tapping Back should return to the timeline")
        XCTAssertTrue(app.buttons["sticker-button"].exists, "Timeline composer should still be visible after Back")

        returnToChatList(app)
    }

    /// The unread count SpringBoard holds for Halo's icon, 0 for none. Read from the icon's accessibility value ("3 new
    /// items"), which is there even while a Focus hides badges on the Home Screen. Halo's widget is also an "icon" labelled
    /// "Halo" and comes first; its value is "Widget". `nil` when the icon isn't on the Home Screen.
    @MainActor
    private func iconBadge() -> Int? {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icons = springboard.icons.matching(NSPredicate(format: "label == 'Halo'")).allElementsBoundByIndex
        guard let icon = icons.first(where: { ($0.value as? String) != "Widget" }) else { return nil }
        return Int((icon.value as? String ?? "").prefix(while: \.isNumber)) ?? 0
    }

    /// Verifies that the SpringBoard app icon badge never changes or disappears across repeated background/foreground and
    /// cold-relaunch cycles that read nothing. Opt-in via `HALO_RUN_DEVICE_CHECKS=1`; the account needs unread messages.
    @MainActor
    func testUnreadBadgePersistsAcrossOpenCloseCycles() throws {
        guard ProcessInfo.processInfo.environment["HALO_RUN_DEVICE_CHECKS"] == "1" else {
            throw XCTSkip("Set HALO_RUN_DEVICE_CHECKS=1 to run SpringBoard badge persistence check.")
        }
        let app = XCUIApplication()
        app.launch()
        dismissFirstRunSheets(app)
        if !chatsRoot(app).waitForExistence(timeout: 3) { returnToChatList(app) }
        guard chatsRoot(app).waitForExistence(timeout: 10) else { throw XCTSkip("App is signed out.") }
        if app.buttons["focus-show-all"].exists { app.buttons["focus-show-all"].tap() }
        _ = app.collectionViews.firstMatch.waitForExistence(timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        guard let expected = iconBadge() else { throw XCTSkip("Halo's icon isn't on the Home Screen.") }
        guard expected > 0 else { throw XCTSkip("The account has no unread messages.") }
        var trace = ["start=\(expected)"]
        func check(_ step: String) {
            let value = iconBadge()
            trace.append("\(step)=\(value.map(String.init) ?? "none")")
            XCTAssertEqual(value, expected, "The badge changed at \(step): \(trace.joined(separator: " "))")
        }

        for cycle in 1...5 {
            app.activate()
            _ = chatsRoot(app).waitForExistence(timeout: 3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            XCUIDevice.shared.press(.home)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            check("background-\(cycle)")
        }
        // Closed again before the first sync can finish: the replica of the last run must not overwrite the icon.
        for cycle in 1...5 {
            app.terminate()
            check("terminated-\(cycle)")
            app.launch()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1 * Double(cycle)))
            XCUIDevice.shared.press(.home)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            check("quick-close-\(cycle)")
        }
        let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
        attachment.name = "icon-badge-trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("ICON_BADGE_TRACE \(trace.joined(separator: " "))")
    }
}

/// `XCTOSSignpostMetric` that keeps what it measured; `measure` itself doesn't hand the values back. (XCTest copies metrics, hence the static.)
final class SignpostReader: XCTOSSignpostMetric {
    /// Seconds by interval name.
    nonisolated(unsafe) static var durations: [String: [Double]] = [:]

    override func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp, to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        let found = try super.reportMeasurements(from: startTime, to: endTime)
        for measurement in found {
            let name = measurement.identifier.replacingOccurrences(of: "com.apple.dt.XCTMetric_OSSignpost-", with: "").replacingOccurrences(of: ".duration", with: "")
            Self.durations[name, default: []].append(measurement.value.value)
        }
        return found
    }
}
