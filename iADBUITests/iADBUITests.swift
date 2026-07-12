import XCTest
import Darwin

final class iADBUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDisconnectedFeatureHasRecoveryPath() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()

        XCTAssertTrue(tabItem("Device", in: app).waitForExistence(timeout: 5))

        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.staticTexts["Device Required"].waitForExistence(timeout: 2))
        let recoveryButton = app.buttons["Open Device"]
        XCTAssertTrue(recoveryButton.exists)
        recoveryButton.tap()

        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testConnectionScreenExposesPairingAndRescanActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["Connect a Device"].waitForExistence(timeout: 5))
        app.buttons["Connect a Device"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Pair Manually"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Rescan"].exists)

        app.buttons["Pair Manually"].tap()
        XCTAssertTrue(app.navigationBars["Pair Device"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["IP address"].exists)
        XCTAssertTrue(app.textFields["Six digit pairing code"].exists)
        app.buttons["Close"].tap()

        app.navigationBars.buttons["Device"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 2))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Privacy Policy"].exists)
        app.buttons["Privacy Policy"].tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()

        let resetIdentity = app.buttons["Reset ADB Identity"]
        XCTAssertTrue(resetIdentity.waitForExistence(timeout: 2))
        resetIdentity.tap()
        XCTAssertTrue(app.buttons["Reset Identity"].waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testConnectedEmptyFileManagerHasReachableActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing-connected"]
        app.launch()

        XCTAssertTrue(tabItem("Files", in: app).waitForExistence(timeout: 5))
        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.staticTexts["Empty Directory"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["New Folder"].exists)
        XCTAssertTrue(app.buttons["Upload"].exists)

        let actions = app.buttons["File actions"]
        XCTAssertTrue(actions.exists)
        actions.tap()
        XCTAssertTrue(app.buttons["Upload File"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Refresh"].exists)
    }

    @MainActor
    func testFirstRunPairingRemainsReachableAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        let connect = app.buttons["Connect a Device"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isHittable)
        connect.tap()

        let pair = app.buttons["Pair Manually"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        var scrollAttempts = 0
        while !pair.isHittable && scrollAttempts < 3 {
            app.scrollViews.firstMatch.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(pair.isHittable)
        pair.tap()

        XCTAssertTrue(app.navigationBars["Pair Device"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["IP address"].exists)
        XCTAssertTrue(app.textFields["Pairing port"].exists)
        XCTAssertTrue(app.textFields["Six digit pairing code"].exists)
        XCTAssertTrue(app.buttons["Close"].exists)
    }

    @MainActor
    func testDeviceUsesTabBarForWorkspaceNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--app-store-screenshots"]
        app.launch()

        XCTAssertTrue(tabItem("Device", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.files"].exists)

        let filesTab = tabItem("Files", in: app)
        XCTAssertTrue(filesTab.isHittable)
        filesTab.tap()

        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'demo-build.apk'"))
                .firstMatch.exists
        )
    }

    @MainActor
    func testDisconnectedRecoveryOverlayScrollsAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-disconnected-error",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(tabItem("Files", in: app).waitForExistence(timeout: 5))
        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.staticTexts["Device Required"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reconnect Last Device"].exists)

        let openDevice = app.buttons["Open Device"]
        XCTAssertTrue(openDevice.exists)
        var scrollAttempts = 0
        while !openDevice.isHittable && scrollAttempts < 4 {
            app.scrollViews.firstMatch.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(openDevice.isHittable)
        openDevice.tap()
        XCTAssertTrue(app.navigationBars["Device"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testConnectedWorkspacesRemainUsableAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--app-store-screenshots",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        let details = app.buttons["View Device Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToHittable(details, in: app.scrollViews.firstMatch))
        details.tap()

        let copyBuild = app.buttons["Copy Build"]
        XCTAssertTrue(scrollToHittable(copyBuild, in: app.scrollViews.firstMatch, maxSwipes: 8))
        XCTAssertGreaterThanOrEqual(copyBuild.frame.height, 43.5)
        app.navigationBars.buttons["Device"].tap()

        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3))
        app.buttons["File actions"].tap()
        XCTAssertTrue(app.buttons["Select Multiple"].waitForExistence(timeout: 2))
        app.buttons["Select Multiple"].tap()

        let fileRow = app.buttons["File demo-build.apk"]
        XCTAssertTrue(scrollToHittable(fileRow, in: app.scrollViews.firstMatch))
        fileRow.tap()
        let clearSelection = app.buttons["Clear Selection"]
        let deleteSelection = app.buttons["Delete"].firstMatch
        XCTAssertTrue(clearSelection.waitForExistence(timeout: 2))
        XCTAssertTrue(deleteSelection.exists)
        assertNonOverlappingControls(clearSelection, deleteSelection)

        tabItem("Apps", in: app).tap()
        let install = app.buttons["Install APK"]
        XCTAssertTrue(install.waitForExistence(timeout: 3))
        let packageSummary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Installed Apps'"))
            .firstMatch
        XCTAssertTrue(packageSummary.exists)
        XCTAssertFalse(packageSummary.frame.intersects(install.frame))
        XCTAssertTrue(install.isHittable)

        tabItem("Console", in: app).tap()
        XCTAssertTrue(app.navigationBars["Console"].waitForExistence(timeout: 3))
        app.segmentedControls.buttons["Logs"].tap()
        let stop = app.buttons["Stop log capture"]
        let pause = app.buttons["Pause log display"]
        let logActions = app.buttons["Log actions"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertTrue(pause.exists)
        XCTAssertTrue(logActions.exists)
        assertNonOverlappingControls(stop, pause)
        assertNonOverlappingControls(pause, logActions)

        tabItem("Screens", in: app).tap()
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 3))
        let capture = app.buttons["Capture screenshot"]
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
        XCTAssertTrue(capture.isHittable)
        XCTAssertGreaterThan(capture.frame.width, 80)

        let screenshot = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Screenshot from'")
        ).firstMatch
        XCTAssertTrue(scrollToHittable(screenshot, in: app.scrollViews.firstMatch, maxSwipes: 5))
        screenshot.tap()
        XCTAssertTrue(app.buttons["Zoom in"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Zoom in"].isHittable)
        XCTAssertTrue(app.buttons["Close screenshot"].isHittable)
    }

    /// Optional local hardware-adjacent smoke test. CI skips this unless an
    /// Android Emulator is listening on 127.0.0.1:5555.
    @MainActor
    func testAndroidEmulatorCoreFlows() throws {
        guard Self.isTCPPortOpen(host: "127.0.0.1", port: 5555) else {
            throw XCTSkip("Start an Android Emulator on 127.0.0.1:5555 to run this test")
        }

        let app = XCUIApplication()
        app.launchArguments += ["--iadb-debug-android-emulator"]
        app.launch()

        let emulator = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Android Emulator'")
        ).firstMatch
        XCTAssertTrue(emulator.waitForExistence(timeout: 10))
        emulator.tap()
        guard app.buttons["View Device Details"].waitForExistence(timeout: 20) else {
            XCTFail("Android Emulator connection did not complete. UI hierarchy:\n\(app.debugDescription)")
            return
        }

        app.buttons["View Device Details"].tap()
        XCTAssertTrue(app.navigationBars["Device Info"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Android SDK built for arm64"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Device"].tap()

        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Android"].waitForExistence(timeout: 20))

        tabItem("Apps", in: app).tap()
        XCTAssertTrue(app.buttons["Install APK"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'com.'"))
                .firstMatch.waitForExistence(timeout: 30)
        )

        tabItem("Console", in: app).tap()
        XCTAssertTrue(app.navigationBars["Console"].waitForExistence(timeout: 5))
        let commandField = app.textFields["Shell command"]
        commandField.tap()
        commandField.typeText("echo iadb-integration")
        app.buttons["Run command"].tap()
        XCTAssertTrue(app.staticTexts["iadb-integration"].waitForExistence(timeout: 20))

        app.segmentedControls.buttons["Logs"].tap()
        app.buttons["Start log capture"].tap()
        XCTAssertTrue(app.buttons["Stop log capture"].waitForExistence(timeout: 10))
        app.buttons["Stop log capture"].tap()

        tabItem("Screens", in: app).tap()
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        app.buttons["Capture screenshot"].tap()
        XCTAssertTrue(app.buttons["Screenshot actions"].waitForExistence(timeout: 20))
    }

    private static func isTCPPortOpen(host: String, port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxSwipes: Int = 5
    ) -> Bool {
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            scrollView.swipeUp()
            attempts += 1
        }
        return element.exists && element.isHittable
    }

    private func assertNonOverlappingControls(
        _ first: XCUIElement,
        _ second: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(first.frame.height, 43.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(second.frame.height, 43.5, file: file, line: line)
        XCTAssertFalse(first.frame.intersects(second.frame), file: file, line: line)
    }

    /// iPhone exposes SwiftUI tabs through a TabBar, while the iPad floating
    /// tab bar can expose the same item as a top-level Button or Cell.
    private func tabItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        if let item = existingTabItem(name, in: app) { return item }

        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    private func existingTabItem(_ name: String, in app: XCUIApplication) -> XCUIElement? {
        let tabBarButton = app.tabBars.buttons[name].firstMatch
        if tabBarButton.exists && tabBarButton.isHittable { return tabBarButton }

        let button = app.buttons[name].firstMatch
        if button.exists && button.isHittable { return button }

        let cell = app.cells[name].firstMatch
        if cell.exists && cell.isHittable { return cell }

        return nil
    }
}
