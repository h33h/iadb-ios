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

        XCTAssertTrue(tabItem("Connect", in: app).waitForExistence(timeout: 5))

        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.staticTexts["Not Connected"].waitForExistence(timeout: 2))
        let recoveryButton = app.buttons["Go to Connect"]
        XCTAssertTrue(recoveryButton.exists)
        recoveryButton.tap()

        XCTAssertTrue(app.navigationBars["iADB"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testConnectionScreenExposesPairingAndRescanActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["Pair Manually"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Rescan"].exists)
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
        guard app.buttons["Disconnect"].waitForExistence(timeout: 20) else {
            XCTFail("Android Emulator connection did not complete. UI hierarchy:\n\(app.debugDescription)")
            return
        }

        tabItem("Device", in: app).tap()
        XCTAssertTrue(app.navigationBars["Device Info"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Android SDK built for arm64"].waitForExistence(timeout: 20))

        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Android"].waitForExistence(timeout: 20))

        tabItem("Apps", in: app).tap()
        XCTAssertTrue(app.buttons["Install APK"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'com.'"))
                .firstMatch.waitForExistence(timeout: 30)
        )

        if let shellTab = existingTabItem("Shell", in: app) {
            shellTab.tap()
        } else {
            tabItem("More", in: app).tap()
            app.staticTexts["Shell"].tap()
        }
        XCTAssertTrue(app.navigationBars["Shell"].waitForExistence(timeout: 5))
        let commandField = app.textFields["Enter command..."]
        commandField.tap()
        commandField.typeText("echo iadb-integration")
        app.buttons["Run command"].tap()
        XCTAssertTrue(app.staticTexts["iadb-integration"].waitForExistence(timeout: 20))

        if let logcatTab = existingTabItem("Logcat", in: app) {
            logcatTab.tap()
        } else if app.buttons["Next Page"].firstMatch.exists {
            app.buttons["Next Page"].firstMatch.tap()
            let logcatTab = tabItem("Logcat", in: app)
            XCTAssertTrue(logcatTab.waitForExistence(timeout: 3))
            logcatTab.tap()
        } else {
            app.navigationBars.buttons["More"].tap()
            app.staticTexts["Logcat"].tap()
        }
        app.buttons["Start log capture"].tap()
        XCTAssertTrue(app.buttons["Stop log capture"].waitForExistence(timeout: 10))
        app.buttons["Stop log capture"].tap()

        if let screenTab = existingTabItem("Screen", in: app) {
            screenTab.tap()
        } else if app.buttons["Next Page"].firstMatch.exists {
            app.buttons["Next Page"].firstMatch.tap()
            let screenTab = tabItem("Screen", in: app)
            XCTAssertTrue(screenTab.waitForExistence(timeout: 3))
            screenTab.tap()
        } else {
            app.navigationBars.buttons["More"].tap()
            app.staticTexts["Screen"].tap()
        }
        XCTAssertTrue(app.navigationBars["Screenshots"].waitForExistence(timeout: 5))
        app.buttons["Capture screenshot"].tap()
        XCTAssertTrue(app.buttons["Delete all screenshots"].waitForExistence(timeout: 20))
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
