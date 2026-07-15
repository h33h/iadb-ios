import XCTest
import Darwin

final class iADBUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStableIdentifiersLocateCoreWorkspaceControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=apps"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["root.device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["root.apps"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["apps.primary.install"].exists)
        let filter = app.buttons["apps.filter"]
        XCTAssertTrue(filter.exists)
        XCTAssertTrue(app.descendants(matching: .any)["apps.list"].exists)
        filter.tap()
        XCTAssertTrue(app.navigationBars["Filter Apps"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["All"].exists)
        app.buttons["Done"].tap()

        let aurora = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Aurora Notes, com.example.auroranotes'")
        ).firstMatch
        XCTAssertTrue(aurora.waitForExistence(timeout: 3))
        aurora.tap()
        XCTAssertTrue(app.navigationBars["App Details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Launch"].exists)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'More actions for'")
        ).count, 0)
    }

    @MainActor
    func testCompactFileSelectionTogglesFilesWithoutOpeningPreview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=files"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) < 1_000 else {
            throw XCTSkip("Compact-width file selection coverage")
        }

        let selectFiles = app.buttons["files.toolbar.select"]
        XCTAssertTrue(selectFiles.waitForExistence(timeout: 3))
        selectFiles.tap()

        let file = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'demo-build.apk, File'")
        ).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 3))
        file.tap()
        XCTAssertEqual(file.value as? String, "Selected")
        XCTAssertFalse(app.navigationBars["Preview"].exists)

        file.tap()
        XCTAssertEqual(file.value as? String, "Not selected")
        XCTAssertFalse(app.navigationBars["Preview"].exists)
    }

    @MainActor
    func testIPadSidebarSwitchesRootsAndPreservesFileContext() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=files"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) >= 1_000 else {
            throw XCTSkip("Regular-width iPad shell coverage")
        }
        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(app.descendants(matching: .any)["shell.split"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["device.context"].exists)
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.navigationBars["Files"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "/sdcard/Download")
        ).firstMatch.exists)
        XCTAssertTrue(app.buttons["Sort by Name"].waitForExistence(timeout: 3))

        let releaseNotes = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'release-notes.txt'")
        ).firstMatch
        XCTAssertTrue(releaseNotes.exists)
        releaseNotes.tap()
        XCTAssertTrue(app.navigationBars["File Inspector"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.buttons["Rename"].exists)

        let appsRoot = app.descendants(matching: .any)["root.apps"].firstMatch
        XCTAssertTrue(appsRoot.exists)
        appsRoot.tap()
        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Sort by App"].waitForExistence(timeout: 3))
        let aurora = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Aurora Notes, com.example.auroranotes'")
        ).firstMatch
        XCTAssertTrue(aurora.waitForExistence(timeout: 3))
        aurora.tap()
        XCTAssertTrue(app.navigationBars["App Inspector"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Launch"].exists)
        XCTAssertTrue(app.buttons["Force Stop"].exists)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'More actions for'")
        ).count, 0)

        let filesRoot = app.descendants(matching: .any)["root.files"].firstMatch
        XCTAssertTrue(filesRoot.exists)
        filesRoot.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["File Inspector"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "/sdcard/Download")
        ).firstMatch.exists)
    }

    @MainActor
    func testIPadAccessibilityXXXLUsesOneColumnComposition() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=connected",
            "--iadb-root=files",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) >= 1_000 else {
            throw XCTSkip("Regular-width iPad accessibility shell coverage")
        }

        XCTAssertFalse(app.descendants(matching: .any)["shell.split"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["device.context"].exists)
        XCTAssertTrue(app.navigationBars["Files"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.files"].exists)
    }

    @MainActor
    func testIPadPortraitKeepsSplitSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=files"]
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) >= 1_000 else {
            throw XCTSkip("Regular-width iPad orientation coverage")
        }
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.height > element.frame.width
            },
            object: window
        )
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["shell.split"].waitForExistence(timeout: 5))
        let releaseNotes = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'release-notes.txt'")
        ).firstMatch
        XCTAssertTrue(releaseNotes.waitForExistence(timeout: 3))
        releaseNotes.tap()
        XCTAssertTrue(app.navigationBars["File Inspector"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["shell.split"].exists)
        XCTAssertTrue(app.navigationBars["File Inspector"].exists)
        XCTAssertTrue(app.buttons["Download"].isHittable)
    }

    @MainActor
    func testIPadDeviceDashboardUsesHealthContentAndConnectionInspector() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=device"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) >= 1_000 else {
            throw XCTSkip("Regular-width iPad Device dashboard coverage")
        }
        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(app.descendants(matching: .any)["shell.split"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Device"].exists)
        XCTAssertTrue(app.navigationBars["Connection Summary"].exists)
        XCTAssertTrue(app.staticTexts["At a Glance"].exists)
        XCTAssertTrue(app.staticTexts["Recent Activity"].exists)
        XCTAssertFalse(app.staticTexts["IP Address"].exists)
    }

    @MainActor
    func testCommandRunnerUsesOneShotHistoryAndIPadInspector() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=console"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let isRegularWidth = max(window.frame.width, window.frame.height) >= 1_000
        if isRegularWidth {
            XCTAssertTrue(app.descendants(matching: .any)["shell.split"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["Console"].exists)
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["workspace.shell"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["Ready"].exists)

        let run = app.buttons["Run command"]
        XCTAssertTrue(run.exists)
        XCTAssertGreaterThanOrEqual(run.frame.height, 43.5)

        let historyEntry = app.descendants(matching: .any)["shell.history.entry"].firstMatch
        XCTAssertTrue(historyEntry.waitForExistence(timeout: 3))
        XCTAssertTrue(historyEntry.label.contains("exit code 0"))
        historyEntry.tap()

        guard isRegularWidth else {
            XCTAssertTrue(app.buttons["Reuse"].waitForExistence(timeout: 2))
            XCTAssertTrue(app.buttons["Copy"].exists)
            XCTAssertTrue(app.buttons["Pin"].exists || app.buttons["Unpin"].exists)
            app.descendants(matching: .any)["shell.history.entry"].firstMatch.tap()
            XCTAssertFalse(app.buttons["Reuse"].waitForExistence(timeout: 1))
            return
        }

        XCTAssertTrue(app.navigationBars["Command Output"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Exit code"].exists)
        XCTAssertTrue(app.staticTexts["0"].exists)
        XCTAssertTrue(app.buttons["Reuse"].exists)
        XCTAssertTrue(app.buttons["Copy"].exists)

        app.descendants(matching: .any)["shell.history.entry"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Select a command"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLogcatSeparatesCaptureFollowAndReviewsExportScope() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected", "--iadb-root=console"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let isRegularWidth = max(window.frame.width, window.frame.height) >= 1_000

        let logcatMode = app.segmentedControls.buttons["Logcat"]
        XCTAssertTrue(logcatMode.waitForExistence(timeout: 5))
        logcatMode.tap()

        XCTAssertTrue(app.buttons["Stop log capture"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pause log display"].exists)
        XCTAssertTrue(app.buttons["Review log export"].exists)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Filter logs'")
        ).firstMatch.exists)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == 'Actions for log entry'")).count,
            0
        )

        app.buttons["Pause log display"].tap()
        XCTAssertTrue(app.buttons["Resume log display"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Stop log capture"].exists)
        app.buttons["Resume log display"].tap()
        XCTAssertTrue(app.buttons["Pause log display"].waitForExistence(timeout: 2))

        let filterLogs = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Filter logs'")
        ).firstMatch
        filterLogs.tap()
        XCTAssertTrue(app.navigationBars["Filter Logs"].waitForExistence(timeout: 3))
        let applyPreset = app.buttons["Apply"].firstMatch
        let filterForm = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.scrollViews.firstMatch
        XCTAssertTrue(scrollToHittable(applyPreset, in: filterForm, maxSwipes: 4))
        applyPreset.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'App lifecycle'")
        ).firstMatch.waitForExistence(timeout: 2))

        if isRegularWidth {
            let row = app.staticTexts["Dashboard ready in 184 ms"]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.tap()
            XCTAssertTrue(app.navigationBars["Log Details"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Copy Message"].exists)
        }

        app.buttons["Review log export"].tap()
        app.buttons["Current filtered view"].tap()
        XCTAssertTrue(app.navigationBars["Export Logs"].waitForExistence(timeout: 3))
        let exportScope = app.descendants(matching: .any)["logcat.export.scope"]
        XCTAssertTrue(exportScope.exists)
        let scopeDescription = "\(exportScope.label) \(exportScope.value ?? "")"
        XCTAssertTrue(scopeDescription.contains("Current filtered view"))
        XCTAssertEqual(app.switches["Redact endpoint and serial"].value as? String, "1")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testScreensSupportsBulkCompareAndAdaptiveInspector() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--app-store-screenshots", "--iadb-root=screens"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let isRegularWidth = max(window.frame.width, window.frame.height) >= 1_000
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["screens.primary.capture"].exists)
        XCTAssertTrue(app.buttons["screens.selection.toggle"].exists)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == 'Actions for screenshot'")
        ).count, 0)

        let thumbnails = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Screenshot from'")
        )
        XCTAssertGreaterThanOrEqual(thumbnails.count, isRegularWidth ? 4 : 5)

        if isRegularWidth {
            let firstRowXPositions = Set((0..<4).map {
                Int(thumbnails.element(boundBy: $0).frame.minX.rounded())
            })
            XCTAssertEqual(firstRowXPositions.count, 4)
            thumbnails.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Screenshot Details"].waitForExistence(timeout: 3))
            let openViewer = app.buttons["Open Viewer"]
            XCTAssertTrue(openViewer.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(openViewer.frame.height, 44)
            XCTAssertTrue(openViewer.isHittable)
            openViewer.tap()
            XCTAssertTrue(app.buttons["Fit"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["100%"].exists)
            XCTAssertTrue(app.buttons["Share screenshot"].exists)
            XCTAssertTrue(app.buttons["Save screenshot to Photos"].exists)
            XCTAssertTrue(app.buttons["Copy screenshot"].exists)
            app.buttons["Close screenshot"].tap()
        }

        let initialScreenshotCount = thumbnails.count
        let capture = app.descendants(matching: .any)["screens.primary.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
        capture.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "count == %d", initialScreenshotCount + 1),
                    object: thumbnails
                )],
                timeout: 3
            ),
            .completed
        )

        let selectScreenshots = app.buttons["screens.selection.toggle"]
        XCTAssertTrue(selectScreenshots.waitForExistence(timeout: 3))
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: selectScreenshots
                )],
                timeout: 3
            ),
            .completed
        )
        selectScreenshots.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2))
        // The freshly captured 1×1 preview image proves the capture path but
        // intentionally differs from the 1080×2400 gallery fixtures. Select
        // two compatible retained screenshots for the comparison workflow.
        thumbnails.element(boundBy: 1).tap()
        thumbnails.element(boundBy: 2).tap()

        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(app.buttons["Compare"].isEnabled)
        app.buttons["Compare"].tap()
        XCTAssertTrue(app.navigationBars["Compare Screenshots"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Fit"].exists)
        XCTAssertTrue(app.buttons["100%"].exists)
        app.navigationBars["Compare Screenshots"].buttons["Done"].tap()

        app.navigationBars["Screens"].buttons["Done"].tap()
        if !isRegularWidth {
            let firstThumbnail = thumbnails.element(boundBy: 1)
            XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 3))
            firstThumbnail.tap()
            XCTAssertTrue(app.buttons["Fit"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["100%"].exists)
            XCTAssertTrue(app.buttons["Share screenshot"].exists)
            XCTAssertTrue(app.buttons["Save screenshot to Photos"].exists)
            XCTAssertTrue(app.buttons["Copy screenshot"].exists)
            app.buttons["Close screenshot"].tap()
        }
    }

    @MainActor
    func testScreensAccessibilityOrderAndSystemAuditInDarkHighContrast() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--app-store-screenshots",
            "--iadb-root=screens",
            "-UIUserInterfaceStyle", "Dark",
            "-UIAccessibilityDarkerSystemColorsEnabled", "YES",
            "-UIAccessibilityReduceMotionEnabled", "YES",
            "-UIAccessibilityVoiceOverEnabled", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        let context = app.descendants(matching: .any)["device.context"]
        let capture = app.descendants(matching: .any)["screens.primary.capture"]
        let thumbnail = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Screenshot from'")
        ).firstMatch
        XCTAssertTrue(context.exists)
        XCTAssertTrue(capture.exists)
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3))

        let orderedElements = app.descendants(matching: .any).allElementsBoundByIndex
        let contextIndex = try XCTUnwrap(orderedElements.firstIndex { $0.identifier == "device.context" })
        let captureIndex = try XCTUnwrap(orderedElements.firstIndex { $0.identifier == "screens.primary.capture" })
        let thumbnailIndex = try XCTUnwrap(orderedElements.firstIndex {
            $0.label.hasPrefix("Screenshot from")
        })
        XCTAssertLessThan(contextIndex, captureIndex)
        XCTAssertLessThan(captureIndex, thumbnailIndex)

        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped
        ])
    }

    @MainActor
    func testCoreWorkspacesPassSystemAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--app-store-screenshots", "--iadb-root=device"]
        app.launch()

        let roots = ["Device", "Files", "Apps", "Console", "Screens"]
        for root in roots {
            tabItem(root, in: app).tap()
            XCTAssertTrue(app.navigationBars[root].waitForExistence(timeout: 4))
            try app.performAccessibilityAudit(for: [
                .hitRegion,
                .sufficientElementDescription,
                .textClipped
            ])
        }
    }

    @MainActor
    func testIPhoneLandscapeKeepsRemotePrimaryActionsReachable() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--app-store-screenshots",
            "--iadb-root=console",
            "--ui-testing-disable-animations",
        ]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) < 1_000 else {
            throw XCTSkip("Compact iPhone landscape coverage")
        }
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.width > element.frame.height
            },
            object: window
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["device.context"].exists)
        XCTAssertTrue(app.navigationBars["Console"].exists)
        let command = app.textFields["Shell command"]
        XCTAssertTrue(command.waitForExistence(timeout: 3))
        XCTAssertTrue(command.isHittable)
        XCTAssertTrue(app.buttons["Run command"].isHittable)

        tabItem("Screens", in: app).tap()
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 3))
        let capture = app.descendants(matching: .any)["screens.primary.capture"]
        XCTAssertTrue(capture.exists)
        XCTAssertTrue(capture.isHittable)
        XCTAssertTrue(app.buttons["screens.selection.toggle"].exists)
    }

    @MainActor
    func testIPhoneFilePreviewPushSurvivesRootSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=connected",
            "--iadb-root=files",
            "--ui-testing-disable-animations",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) < 1_000 else {
            throw XCTSkip("Compact iPhone navigation coverage")
        }

        let releaseNotes = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'release-notes.txt'")
        ).firstMatch
        XCTAssertTrue(releaseNotes.waitForExistence(timeout: 3))
        releaseNotes.tap()

        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 3))
        let previewName = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'File name,'")
        ).firstMatch
        XCTAssertTrue(previewName.exists)
        XCTAssertTrue(app.descendants(matching: .any)["files.preview"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
        ])

        tabItem("Apps", in: app).tap()
        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 3))
        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 3))
        XCTAssertTrue(previewName.exists)
        XCTAssertTrue(app.descendants(matching: .any)["files.preview"].exists)
    }

    @MainActor
    func testIPhoneFilePreviewReflowsAtAccessibilityXXXL() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=connected",
            "--iadb-root=files",
            "--ui-testing-disable-animations",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard max(window.frame.width, window.frame.height) < 1_000 else {
            throw XCTSkip("Compact iPhone Accessibility XXXL preview coverage")
        }

        let search = app.searchFields["Search Files"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("release-notes")
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }

        let releaseNotes = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'release-notes.txt'")
        ).firstMatch
        XCTAssertTrue(waitForHittable(releaseNotes, timeout: 3))
        releaseNotes.tap()

        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 3))
        let type = app.staticTexts["Type"]
        let size = app.staticTexts["Size"]
        let modified = app.staticTexts["Modified"]
        XCTAssertTrue(type.exists)
        XCTAssertTrue(size.exists)
        XCTAssertTrue(modified.exists)
        XCTAssertEqual(type.frame.minX, size.frame.minX, accuracy: 2)
        XCTAssertEqual(size.frame.minX, modified.frame.minX, accuracy: 2)
        XCTAssertGreaterThan(size.frame.minY, type.frame.maxY)
        XCTAssertGreaterThan(modified.frame.minY, size.frame.maxY)
        XCTAssertGreaterThanOrEqual(type.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(modified.frame.maxX, window.frame.maxX)

        try app.performAccessibilityAudit(for: [
            .hitRegion,
            .sufficientElementDescription,
            .textClipped,
        ])
    }

    @MainActor
    func testScreenshotDeleteRequiresExplicitSelectionAndConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--app-store-screenshots", "--iadb-root=screens"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete"].exists)
        app.buttons["Select"].tap()
        let thumbnails = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Screenshot from'")
        )
        thumbnails.element(boundBy: 0).tap()
        thumbnails.element(boundBy: 1).tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Delete Selected Screenshots?"].waitForExistence(timeout: 3))
        XCTAssertEqual(thumbnails.count, 5)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(thumbnails.count, 5)
    }

    @MainActor
    func testActivityCenterKeepsOperationVisibleOutsideItsWorkspace() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=operation-progress", "--iadb-root=files"]
        app.launch()

        let activity = app.descendants(matching: .any)["activity.open"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()

        XCTAssertTrue(app.descendants(matching: .any)["activity.center"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["activity.operation.object"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["activity.operation.device-phase"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["activity.foreground.message"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testFileUploadProgressDoesNotBlockFilesContent() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=file-upload-progress",
            "--iadb-root=files",
            "--ui-testing-disable-animations",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["Search Files"].exists)
        XCTAssertFalse(app.buttons["files.toolbar.upload"].isEnabled)
        XCTAssertTrue(app.buttons["files.toolbar.select"].isEnabled)

        let activity = app.descendants(matching: .any)["activity.open"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.tap()
        XCTAssertTrue(app.staticTexts["release-bundle.zip"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.progressIndicators["Operation progress"].exists)
        XCTAssertTrue(
            String(describing: app.progressIndicators["Operation progress"].value ?? "")
                .contains("25")
        )
        XCTAssertTrue(app.staticTexts["Uploading to /sdcard/Download…"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Done"].tap()

        let releaseNotes = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'release-notes.txt'")
        ).firstMatch
        XCTAssertTrue(releaseNotes.waitForExistence(timeout: 3))
        releaseNotes.tap()
        XCTAssertTrue(app.navigationBars["Preview"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAPKInstallProgressNamesTargetAndKeepsAppsBrowsable() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=operation-progress",
            "--iadb-root=apps",
            "--ui-testing-disable-animations",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Apps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Uploading demo-build.apk — 41%"].exists)
        XCTAssertFalse(app.buttons["apps.primary.install"].isEnabled)
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Aurora Notes, com.example.auroranotes'")
        ).firstMatch.exists)

        let activity = app.descendants(matching: .any)["activity.open"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.tap()
        XCTAssertTrue(app.staticTexts["demo-build.apk"].waitForExistence(timeout: 3))
        let targetPhase = app.descendants(matching: .any)["activity.operation.device-phase"]
        XCTAssertTrue(targetPhase.exists)
        XCTAssertTrue(targetPhase.label.contains("Demo Android"))
        XCTAssertTrue(app.progressIndicators["Operation progress"].exists)
        XCTAssertTrue(
            String(describing: app.progressIndicators["Operation progress"].value ?? "")
                .contains("41")
        )
        app.buttons["Done"].tap()
    }

    @MainActor
    func testCommandProgressStreamsSeparateOutputAndCanStop() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=command-progress",
            "--iadb-root=console",
            "--ui-testing-disable-animations",
        ]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.shell"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop command"].exists)
        XCTAssertTrue(app.staticTexts["/sdcard/Download/release-notes.txt\n/sdcard/Download/demo-build.apk\n"].exists)
        XCTAssertTrue(app.staticTexts["find: /sdcard/Android/data: Permission denied\n"].exists)

        app.buttons["Stop command"].tap()
        XCTAssertTrue(app.buttons["Run command"].waitForExistence(timeout: 3))
        let interrupted = app.descendants(matching: .any)
            .matching(identifier: "shell.history.entry")
            .matching(NSPredicate(
                format: "label CONTAINS 'find /sdcard/Download' AND label CONTAINS 'interrupted'"
            ))
            .firstMatch
        XCTAssertTrue(interrupted.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPartialBulkFixtureShowsPerItemFailuresAndRetainsSelection() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--iadb-fixture=partial-bulk-failure",
            "--iadb-root=files",
            "--ui-testing-disable-animations",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["4 succeeded, 2 failed"].exists)

        let failedStatuses = app.images.matching(
            NSPredicate(format: "label BEGINSWITH 'Could not delete'")
        )
        XCTAssertEqual(failedStatuses.count, 2)

        let failedRows = app.buttons.matching(
            NSPredicate(format: "value == 'Selected'")
        )
        XCTAssertEqual(failedRows.count, 2)
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    @MainActor
    func testDisconnectedFeatureHasRecoveryPath() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing-disconnected-error"]
        app.launch()

        XCTAssertTrue(tabItem("Device", in: app).waitForExistence(timeout: 5))

        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["device.context"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.files"].exists)
        XCTAssertFalse(app.staticTexts["Device Required"].exists)

        let context = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Device context'")
        ).firstMatch
        XCTAssertTrue(context.exists)
        context.tap()
        XCTAssertTrue(app.descendants(matching: .any)["device.switcher"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Manage Connections"].exists)
    }

    @MainActor
    func testConnectionScreenExposesPairingAndRescanActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()

        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect a Device"].waitForExistence(timeout: 5))
        app.buttons["Connect a Device"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.buttons["Pair Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.staticTexts["Not Connected"].exists)
        XCTAssertFalse(app.buttons["Run Connection Check"].exists)

        app.buttons["Pair Device"].tap()
        XCTAssertTrue(app.navigationBars["Pair Device"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["IP address"].exists)
        XCTAssertTrue(app.textFields["Six digit pairing code"].exists)
        XCTAssertFalse(app.staticTexts["Pair over local Wi-Fi"].exists)
        XCTAssertFalse(app.buttons["Paste"].exists)
        app.buttons["Close"].tap()
    }

    @MainActor
    func testSettingsUsesFocusedSectionsAndFullScreenConnections() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iadb-fixture=connected"]
        app.launch()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 2))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Screenshot storage"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings.screenshotRetention"].exists)
        XCTAssertFalse(app.buttons["Open Source Licenses"].exists)
        XCTAssertFalse(app.buttons["Reset ADB Identity"].exists)

        let privacyPolicy = app.buttons["Privacy Policy"]
        XCTAssertTrue(scrollToHittable(privacyPolicy, in: app.collectionViews.firstMatch, maxSwipes: 8))
        privacyPolicy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()

        let connections = app.descendants(matching: .any)["settings.connections"]
        XCTAssertTrue(scrollToHittable(connections, in: app.collectionViews.firstMatch, maxSwipes: 8))
        connections.tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Done"].exists)
        let resetIdentity = app.buttons["Reset ADB Identity"]
        XCTAssertTrue(scrollToHittable(
            resetIdentity,
            in: app.collectionViews.firstMatch,
            maxSwipes: 8
        ))
        resetIdentity.tap()
        XCTAssertTrue(app.buttons["Reset Identity"].waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testConnectedEmptyFileManagerHasReachableActions() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-connected",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(tabItem("Files", in: app).waitForExistence(timeout: 5))
        tabItem("Files", in: app).tap()

        XCTAssertTrue(app.staticTexts["Empty Directory"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["New Folder"].exists)
        XCTAssertTrue(app.buttons["Upload"].exists)

        let newAction = app.buttons["New"]
        XCTAssertTrue(newAction.exists)
        XCTAssertTrue(app.buttons["Select"].exists)
        newAction.tap()
        let newFolder = app.buttons["folder.badge.plus"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 2))
        newFolder.tap()

        XCTAssertTrue(app.descendants(matching: .any)["files.operationForm"].waitForExistence(timeout: 2))
        let name = app.textFields["files.operationForm.input"]
        XCTAssertTrue(name.exists)
        let submit = app.buttons["files.operationForm.submit"]
        XCTAssertFalse(submit.isEnabled)
        name.tap()
        name.typeText("Reports")
        XCTAssertTrue(submit.isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["files.operationForm"].exists)
    }

    @MainActor
    func testFirstRunPairingRemainsReachableAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let connect = app.buttons["Connect a Device"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isHittable)
        connect.tap()

        let pair = app.buttons["Pair Device"]
        XCTAssertTrue(scrollToHittable(pair, in: app.collectionViews.firstMatch, maxSwipes: 8))
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
    func testDisconnectedDeviceContextReflowsAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing-disconnected-error",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(tabItem("Files", in: app).waitForExistence(timeout: 5))
        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["device.context"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Files"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.files"].exists)
        XCTAssertFalse(app.staticTexts["Device Required"].exists)
        let reconnect = app.buttons["Reconnect"]
        XCTAssertTrue(reconnect.exists)
        XCTAssertTrue(reconnect.isHittable)
        XCTAssertGreaterThanOrEqual(reconnect.frame.height, 43.5)
    }

    @MainActor
    func testConnectedWorkspacesRemainUsableAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--app-store-screenshots",
            "--ui-testing-disable-animations",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let details = app.descendants(matching: .any)["device.primary.details"]
        XCTAssertTrue(scrollToHittable(details, in: app.scrollViews.firstMatch, maxSwipes: 8))
        details.tap()

        let copyBuild = app.buttons["Copy Build"]
        XCTAssertTrue(scrollToHittable(copyBuild, in: app.collectionViews.firstMatch, maxSwipes: 8))
        XCTAssertGreaterThanOrEqual(copyBuild.frame.height, 43.5)
        app.navigationBars.buttons["Device"].tap()

        tabItem("Files", in: app).tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 3))
        let selectFiles = app.buttons["files.toolbar.select"]
        XCTAssertTrue(selectFiles.waitForExistence(timeout: 2))
        selectFiles.tap()

        let fileRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Photos, Folder'")
        ).firstMatch
        XCTAssertTrue(
            scrollToHittable(fileRow, in: app.collectionViews.firstMatch, maxSwipes: 4)
        )
        fileRow.tap()
        let bulkActions = app.buttons["Bulk Actions"]
        XCTAssertTrue(bulkActions.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForHittable(bulkActions, timeout: 3))
        XCTAssertGreaterThanOrEqual(bulkActions.frame.height, 43.5)
        XCTAssertTrue(fileRow.isHittable)
        bulkActions.tap()
        let clearSelection = app.buttons["Clear Selection"]
        let deleteSelection = app.buttons["Delete"].firstMatch
        XCTAssertTrue(clearSelection.waitForExistence(timeout: 2))
        XCTAssertTrue(deleteSelection.exists)
        assertNonOverlappingControls(clearSelection, deleteSelection)
        clearSelection.tap()

        tabItem("Apps", in: app).tap()
        let install = app.buttons["Install APK"]
        XCTAssertTrue(install.waitForExistence(timeout: 3))
        XCTAssertTrue(install.isHittable)
        XCTAssertGreaterThanOrEqual(install.frame.height, 43.5)
        let appFilter = app.buttons["apps.filter"]
        XCTAssertTrue(appFilter.exists)
        XCTAssertTrue(appFilter.isHittable)
        let appRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Aurora Notes, com.example.auroranotes'")
        ).firstMatch
        XCTAssertTrue(appRow.exists)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'More actions for'")
        ).count, 0)

        tabItem("Console", in: app).tap()
        XCTAssertTrue(app.navigationBars["Console"].waitForExistence(timeout: 3))
        let logcatSegment = app.segmentedControls.buttons["Logcat"]
        if logcatSegment.exists {
            logcatSegment.tap()
        } else {
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Console mode'")
            ).firstMatch.tap()
            app.buttons["Logcat"].tap()
        }
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
        XCTAssertGreaterThanOrEqual(capture.frame.width, 43.5)

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
        let deviceDetails = app.descendants(matching: .any)["device.primary.details"]
        guard deviceDetails.waitForExistence(timeout: 20) else {
            XCTFail("Android Emulator connection did not complete. UI hierarchy:\n\(app.debugDescription)")
            return
        }

        deviceDetails.tap()
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

        app.segmentedControls.buttons["Logcat"].tap()
        app.buttons["Start log capture"].tap()
        XCTAssertTrue(app.buttons["Stop log capture"].waitForExistence(timeout: 10))
        app.buttons["Stop log capture"].tap()

        tabItem("Screens", in: app).tap()
        XCTAssertTrue(app.navigationBars["Screens"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["screens.primary.capture"].tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Screenshot from'")
        ).firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == 'Actions for screenshot'")
        ).count, 0)
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
            let elementIsAboveViewport = element.exists && element.frame.maxY < scrollView.frame.minY
            let startY = elementIsAboveViewport ? 0.30 : 0.70
            let endY = elementIsAboveViewport ? 0.70 : 0.30
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.isHittable },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
        let stableIdentifier = "root.\(name.lowercased())"
        let stableButton = app.buttons[stableIdentifier].firstMatch
        if stableButton.exists && stableButton.isHittable { return stableButton }

        let rootOrder = ["Device", "Files", "Apps", "Console", "Screens"]
        if let index = rootOrder.firstIndex(of: name) {
            let indexedTabButton = app.tabBars.buttons.element(boundBy: index)
            if indexedTabButton.exists && indexedTabButton.isHittable { return indexedTabButton }
        }

        let stableItem = app.descendants(matching: .any)[stableIdentifier].firstMatch
        if stableItem.exists && stableItem.isHittable { return stableItem }

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
