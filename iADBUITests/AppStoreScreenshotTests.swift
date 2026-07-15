import XCTest
import UIKit

/// Deterministic App Store captures. This suite must only be launched through
/// `scripts/capture-app-store-screenshots.sh`, which exports the named
/// attachments and validates their pixel format.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = launchDemo()

        assertDemoFixture(in: app)
        capture("01-device", in: app)

        openTab("Files", in: app)
        XCTAssertTrue(element(containingLabel: "Photos", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containingLabel: "demo-build.apk", in: app).exists)
        selectRegularWidthInspector(
            rowContaining: "release-notes.txt",
            navigationTitle: "File Inspector",
            in: app
        )
        capture("02-files", in: app)

        openTab("Console", in: app)
        XCTAssertTrue(app.navigationBars["Console"].waitForExistence(timeout: 5))

        selectConsoleMode("Command Runner", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["Pinned Commands"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'getprop ro.build.version.release'"))
                .firstMatch.waitForExistence(timeout: 5)
        )
        let historyEntry = app.descendants(matching: .any)["shell.history.entry"].firstMatch
        XCTAssertTrue(historyEntry.exists)
        XCTAssertTrue(historyEntry.label.contains("exit code 0"))
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Actions for '")).count,
            0
        )
        if usesRegularWidthWorkspace(app) {
            historyEntry.tap()
            XCTAssertTrue(app.navigationBars["Command Output"].waitForExistence(timeout: 5))
        }
        capture("03-shell", in: app)

        selectConsoleMode("Logcat", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Dashboard ready in 184 ms'"))
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Filter logs'")
        ).firstMatch.exists)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == 'Actions for log entry'")).count,
            0
        )
        selectRegularWidthInspector(
            rowContaining: "Dashboard ready in 184 ms",
            navigationTitle: "Log Details",
            in: app
        )
        capture("05-logs", in: app)

        openTab("Apps", in: app)
        XCTAssertTrue(element(containingLabel: "Aurora Notes", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element(containingLabel: "Canvas Demo", in: app).exists)
        selectRegularWidthInspector(
            rowContaining: "Aurora Notes",
            navigationTitle: "App Inspector",
            in: app
        )
        capture("04-apps", in: app)

        openTab("Screens", in: app)
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Screenshot from'"))
                .firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == 'Actions for screenshot'")
        ).count, 0)
        XCTAssertTrue(app.descendants(matching: .any)["screens.primary.capture"].exists)
        XCTAssertTrue(app.buttons["Select"].exists)
        revealLowerContentOnCompactScreen(in: app)
        if usesRegularWidthWorkspace(app) {
            let screenshot = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Screenshot from'"))
                .firstMatch
            XCTAssertTrue(screenshot.isHittable)
            screenshot.tap()
            XCTAssertTrue(app.navigationBars["Screenshot Details"].waitForExistence(timeout: 5))
        }
        capture("06-screens", in: app)
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--app-store-screenshots",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Light",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        configureOrientation(for: app)
        return app
    }

    @MainActor
    private func configureOrientation(for app: XCUIApplication) {
        let window = app.windows.firstMatch
        let requestedOrientation: UIDeviceOrientation = .portrait
        XCUIDevice.shared.orientation = requestedOrientation

        let orientationPredicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.frame.height > element.frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: orientationPredicate, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func assertDemoFixture(in app: XCUIApplication) {
        XCTAssertTrue(element(containingLabel: "Studio Android", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(containingLabel: "192.168.50.42", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) {
        let item = tabItem(name, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing \(name) tab")
        XCTAssertTrue(item.isHittable, "\(name) tab is not hittable")
        item.tap()

        guard !waitForSelection(of: item, timeout: 2) else { return }

        // Liquid Glass tab items can occasionally shift while settling after
        // a scroll. Re-resolve the element before one deterministic retry.
        let retryItem = tabItem(name, in: app)
        XCTAssertTrue(retryItem.isHittable, "\(name) tab is not hittable after retry")
        retryItem.tap()
        XCTAssertTrue(
            waitForSelection(of: retryItem, timeout: 2),
            "\(name) tab did not become selected"
        )
    }

    @MainActor
    private func waitForSelection(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func selectConsoleMode(_ name: String, in app: XCUIApplication) {
        let segmentedButton = app.segmentedControls.buttons[name].firstMatch
        let button = segmentedButton.exists
            ? segmentedButton
            : app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch

        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(name) Console mode")
        if !button.isSelected {
            button.tap()
        }
    }

    /// iPhone uses a bottom TabBar. iPad can expose its floating tab bar as
    /// top-level buttons or cells, so selectors stay based on accessible labels.
    @MainActor
    private func tabItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let tabBarButton = app.tabBars.buttons[name].firstMatch
        if tabBarButton.exists && tabBarButton.isHittable { return tabBarButton }

        let rootIdentifier = "root.\(name.lowercased())"
        let identified = app.descendants(matching: .any)[rootIdentifier].firstMatch
        if identified.exists && identified.isHittable { return identified }

        let button = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        if button.exists && button.isHittable { return button }

        let cell = app.cells.matching(NSPredicate(format: "label == %@", name)).firstMatch
        if cell.exists && cell.isHittable { return cell }

        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    @MainActor
    private func element(containingLabel text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    private func selectRegularWidthInspector(
        rowContaining text: String,
        navigationTitle: String,
        in app: XCUIApplication
    ) {
        guard usesRegularWidthWorkspace(app) else { return }

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing row containing \(text)")
        XCTAssertTrue(row.isHittable, "Row containing \(text) is not hittable")
        row.tap()
        XCTAssertTrue(
            app.navigationBars[navigationTitle].waitForExistence(timeout: 5),
            "Missing \(navigationTitle) after selecting \(text)"
        )
    }

    @MainActor
    private func usesRegularWidthWorkspace(_ app: XCUIApplication) -> Bool {
        app.windows.firstMatch.frame.width >= 1_000
    }

    @MainActor
    private func revealLowerContentOnCompactScreen(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.frame.width < 800 else { return }

        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.54))
        start.press(forDuration: 0.05, thenDragTo: end)
        waitForRenderingToSettle()
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground)
        waitForRenderingToSettle()

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForRenderingToSettle() {
        let noEvent = expectation(description: "Wait for navigation and rendering")
        noEvent.isInverted = true
        wait(for: [noEvent], timeout: 0.4)
    }
}
