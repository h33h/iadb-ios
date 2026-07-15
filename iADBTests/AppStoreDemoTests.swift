#if DEBUG
import Testing
@testable import iADB

@Suite("Deterministic UI fixtures")
struct AppStoreDemoTests {
    @Test("Every required fixture has a launch argument and reproducible state")
    func everyFixtureIsResolvable() {
        for fixture in AppFixture.allCases {
            #expect(
                AppStoreDemo.fixture(from: ["--iadb-fixture", fixture.rawValue]) == fixture
            )
            _ = AppStoreDemo.state(for: fixture)
        }
    }

    @Test("Inline fixture syntax is supported")
    func inlineFixtureSyntax() {
        #expect(
            AppStoreDemo.fixture(from: ["--iadb-fixture=partial-bulk-failure"])
                == .partialBulkFailure
        )
    }

    @Test("App Store screenshots retain the connected fixture")
    func appStoreFixture() {
        #expect(AppStoreDemo.fixture(from: ["--app-store-screenshots"]) == .connected)
    }

    @Test("Entry fixtures stay behind the connection gate and connected fixtures open workspaces")
    func connectionGateFixtures() {
        let firstLaunch = AppStoreDemo.state(for: .firstLaunch)
        #expect(!firstLaunch.hasEnteredWorkspace)
        #expect(!firstLaunch.isConnectionSetupPresented)

        for fixture in [AppFixture.scanning, .pairing, .connecting, .connectionError] {
            let state = AppStoreDemo.state(for: fixture)
            #expect(!state.hasEnteredWorkspace)
            #expect(state.isConnectionSetupPresented)
        }

        #expect(AppStoreDemo.state(for: .connected).hasEnteredWorkspace)
        #expect(AppStoreDemo.state(for: .disconnected).hasEnteredWorkspace)
        #expect(AppStoreDemo.state(for: .reconnecting).hasEnteredWorkspace)
    }

    @Test("Root launch argument is independent from data fixture")
    func rootLaunchArgument() {
        #expect(AppStoreDemo.root(from: ["--iadb-root=files"]) == .files)
        #expect(AppStoreDemo.root(from: ["--iadb-root", "console"]) == .console)
        #expect(AppStoreDemo.root(from: ["--iadb-root=unknown"]) == nil)
    }

    @Test("Partial bulk fixture preserves individual outcomes and failed selection")
    func partialBulkFixture() {
        let state = AppStoreDemo.state(for: .partialBulkFailure)

        #expect(state.fileManager.bulkOperation?.succeededCount == 4)
        #expect(state.fileManager.bulkOperation?.failedCount == 2)
        #expect(state.fileManager.operationSummary == "4 succeeded, 2 failed")
        #expect(state.fileManager.errorMessage == nil)

        let items = state.fileManager.bulkOperation?.items ?? []
        let failedPaths = Set(items.compactMap { item -> String? in
            if case .failed = item.phase { return item.entry.fullPath }
            return nil
        })
        #expect(state.fileManager.selectedEntryPaths == failedPaths)
    }

    @Test("Transfer, install, and command fixtures expose truthful active state")
    func activeOperationFixtures() {
        let upload = AppStoreDemo.state(for: .fileUploadProgress)
        #expect(upload.fileManager.activeBackgroundOperationID != nil)
        #expect(upload.operations.operations.first?.kind == .upload)
        #expect(upload.operations.operations.first?.progressFraction == 0.25)
        #expect(upload.operations.operations.first?.objectName == "release-bundle.zip")

        let install = AppStoreDemo.state(for: .operationProgress)
        #expect(install.apps.isInstalling)
        #expect(install.operations.operations.first?.kind == .installAPK)
        #expect(install.operations.operations.first?.deviceID == install.apps.remoteTarget.deviceID)

        let command = AppStoreDemo.state(for: .commandProgress)
        #expect(command.shell.isExecuting)
        #expect(command.shell.activeExecution?.state == .running)
        #expect(command.shell.activeExecution?.stdout.contains("release-notes.txt") == true)
        #expect(command.shell.activeExecution?.stderr.contains("Permission denied") == true)
    }
}
#endif
