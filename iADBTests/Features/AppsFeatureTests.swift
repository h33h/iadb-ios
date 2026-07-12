import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct AppsFeatureTests {
    @Test
    func loadAppsSuccess() async {
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.listPackages = { _ in ["com.example.app1", "com.example.app2"] }
        }

        await store.send(.loadApps) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        // AppInfo generates UUID on init, can't match exactly
        store.exhaustivity = .off
        await store.receive(\.appsLoaded.success)
        store.exhaustivity = .on

        #expect(store.state.isLoading == false)
        #expect(store.state.apps.count == 2)
        #expect(store.state.apps[0].packageName == "com.example.app1")
        #expect(store.state.apps[1].packageName == "com.example.app2")
    }

    @Test
    func loadAppsError() async {
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.listPackages = { _ in throw ADBError.notConnected }
        }

        await store.send(.loadApps) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.appsLoaded.failure) {
            $0.isLoading = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
    }

    @Test
    func uninstallSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let store = TestStore(
            initialState: AppsFeature.State(apps: [app])
        ) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.uninstallPackage = { _, _ in "Success" }
            $0.adbClient.listPackages = { _ in [] }
            $0.uuid = .constant(operationID)
        }

        await store.send(.uninstall(app, keepData: false)) {
            $0.activeOperation = AppsFeature.ActiveOperation(
                id: operationID,
                packageName: app.packageName,
                kind: .uninstall
            )
            $0.statusMessage = nil
            $0.errorMessage = nil
        }

        await store.receive(\.operationSucceeded) {
            $0.activeOperation = nil
            $0.statusMessage = "Success"
        }

        await store.receive(\.loadApps) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.appsLoaded.success) {
            $0.isLoading = false
            $0.apps = []
        }
    }

    @Test
    func forceStopSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        let stoppedPackage = LockIsolated<String?>(nil)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.forceStopApp = { name in stoppedPackage.setValue(name) }
            $0.uuid = .constant(operationID)
        }

        await store.send(.forceStop(app)) {
            $0.activeOperation = AppsFeature.ActiveOperation(id: operationID, packageName: app.packageName, kind: .forceStop)
            $0.statusMessage = nil
            $0.errorMessage = nil
        }
        await store.receive(\.operationSucceeded) {
            $0.activeOperation = nil
            $0.statusMessage = "Force stopped com.test.app"
        }
        #expect(stoppedPackage.value == "com.test.app")
    }

    @Test
    func clearDataSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.clearAppData = { _ in "Success" }
            $0.uuid = .constant(operationID)
        }

        await store.send(.clearData(app)) {
            $0.activeOperation = AppsFeature.ActiveOperation(id: operationID, packageName: app.packageName, kind: .clearData)
            $0.statusMessage = nil
            $0.errorMessage = nil
        }
        await store.receive(\.operationSucceeded) {
            $0.activeOperation = nil
            $0.statusMessage = "Success"
        }
    }

    @Test
    func getAppDetailSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let detailID = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.getAppInfo = { _ in "versionName=1.0\nversionCode=42\ntargetSdk=34\nfirstInstallTime=2024-01-01\nlastUpdateTime=2024-01-02\npkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]" }
            $0.uuid = .constant(detailID)
        }

        await store.send(.getAppDetail(app)) {
            $0.selectedApp = app
            $0.isLoadingDetail = true
            $0.activeAppDetailID = detailID
            $0.activeAppDetailPackageName = app.packageName
        }
        await store.receive(\.appDetailLoaded) {
            $0.isLoadingDetail = false
            $0.activeAppDetailID = nil
            $0.activeAppDetailPackageName = nil
            $0.appDetailText = "versionName=1.0\nversionCode=42\ntargetSdk=34\nfirstInstallTime=2024-01-01\nlastUpdateTime=2024-01-02\npkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]"
            $0.appDetail = AppDetail(
                packageName: "com.test.app",
                versionName: "1.0",
                versionCode: "42",
                targetSdk: "34",
                firstInstallTime: "2024-01-01",
                lastUpdateTime: "2024-01-02",
                installerPackage: nil,
                flags: ["HAS_CODE", "ALLOW_CLEAR_USER_DATA"],
                rawText: "versionName=1.0\nversionCode=42\ntargetSdk=34\nfirstInstallTime=2024-01-01\nlastUpdateTime=2024-01-02\npkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]"
            )
            $0.showingAppDetail = true
        }
    }

    @Test
    func newerAppDetailRequestCancelsStaleResponse() async {
        let first = AppInfo(packageName: "com.test.first")
        let second = AppInfo(packageName: "com.test.second")
        let detailID = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.getAppInfo = { packageName in
                if packageName == first.packageName {
                    try await Task.sleep(for: .seconds(60))
                    return "versionName=stale"
                }
                return "versionName=2.0"
            }
            $0.uuid = .constant(detailID)
        }

        await store.send(.getAppDetail(first)) {
            $0.selectedApp = first
            $0.isLoadingDetail = true
            $0.activeAppDetailID = detailID
            $0.activeAppDetailPackageName = first.packageName
        }
        await store.send(.getAppDetail(second)) {
            $0.selectedApp = second
            $0.activeAppDetailPackageName = second.packageName
        }
        store.exhaustivity = .off
        await store.receive(\.appDetailLoaded)
        store.exhaustivity = .on

        #expect(store.state.selectedApp?.packageName == second.packageName)
        #expect(store.state.appDetail?.packageName == second.packageName)
        #expect(store.state.appDetail?.versionName == "2.0")
    }

    @Test
    func queuedDetailFromPreviousPackageCannotOverwriteCurrentPackage() async {
        let first = AppInfo(packageName: "com.test.first")
        let second = AppInfo(packageName: "com.test.second")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000074")!
        let store = TestStore(initialState: AppsFeature.State(
            selectedApp: second,
            isLoadingDetail: true,
            activeAppDetailID: secondID,
            activeAppDetailPackageName: second.packageName
        )) {
            AppsFeature()
        }

        await store.send(.appDetailLoaded(
            id: firstID,
            packageName: first.packageName,
            .success("versionName=stale")
        ))
        #expect(store.state.isLoadingDetail)
        #expect(store.state.appDetail == nil)

        await store.send(.appDetailLoaded(
            id: secondID,
            packageName: second.packageName,
            .success("versionName=2.0")
        )) {
            $0.isLoadingDetail = false
            $0.activeAppDetailID = nil
            $0.activeAppDetailPackageName = nil
            $0.appDetailText = "versionName=2.0"
            $0.appDetail = AppDetail.parse(
                packageName: second.packageName,
                rawText: "versionName=2.0"
            )
            $0.showingAppDetail = true
        }
    }

    @Test
    func launchAppSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000064")!
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "Events injected: 1" }
            $0.uuid = .constant(operationID)
        }

        await store.send(.launchApp(app)) {
            $0.activeOperation = AppsFeature.ActiveOperation(id: operationID, packageName: app.packageName, kind: .launch)
            $0.statusMessage = nil
            $0.errorMessage = nil
        }
        await store.receive(\.operationSucceeded) {
            $0.activeOperation = nil
            $0.statusMessage = "Launched com.test.app"
        }
    }

    @Test
    func repeatedAndStaleOperationsCannotOverwriteCurrentOperation() async {
        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000065")!
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000066")!
        let app = AppInfo(packageName: "com.test.app")
        let active = AppsFeature.ActiveOperation(id: currentID, packageName: app.packageName, kind: .clearData)
        let store = TestStore(initialState: AppsFeature.State(activeOperation: active)) {
            AppsFeature()
        }

        await store.send(.launchApp(app))
        await store.send(.operationSucceeded(id: staleID, message: "stale", reloadApps: false))
        #expect(store.state.activeOperation == active)
        #expect(store.state.statusMessage == nil)
    }

    @Test
    func toggleSystemApps() async {
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        }

        await store.send(.toggleSystemApps) {
            $0.showSystemApps = true
            $0.filter = .all
        }
    }

    @Test
    func setFilterAndSort() async {
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        }

        await store.send(.setFilter(.system)) {
            $0.filter = .system
            $0.showSystemApps = true
        }

        await store.send(.setSort(.package)) {
            $0.sort = .package
        }
    }

    @Test
    func dismissStatus() async {
        let store = TestStore(
            initialState: AppsFeature.State(statusMessage: "Done")
        ) {
            AppsFeature()
        }

        await store.send(.dismissStatus) {
            $0.statusMessage = nil
        }
    }

    @Test
    func filteredApps() async {
        let state = AppsFeature.State(
            apps: [
                AppInfo(packageName: "com.google.chrome", isSystemApp: false),
                AppInfo(packageName: "com.spotify.music", isSystemApp: false),
                AppInfo(packageName: "com.google.maps", isSystemApp: true)
            ],
            filter: .all,
            searchText: "google"
        )
        #expect(state.filteredApps.count == 2)
    }

    @Test
    func systemFilterOnlyShowsSystemApps() async {
        let state = AppsFeature.State(
            apps: [
                AppInfo(packageName: "com.android.settings", isSystemApp: true),
                AppInfo(packageName: "com.example.app", isSystemApp: false)
            ],
            filter: .system
        )

        #expect(state.filteredApps.map(\.packageName) == ["com.android.settings"])
    }

    @Test
    func installAPKSuccess() async {
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let remotePath = "/data/local/tmp/iadb-upload-\(installID.uuidString).apk"
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.pushData = { _, _, _ in }
            $0.adbClient.shell = { _ in "Success" }
            $0.adbClient.listPackages = { _ in [] }
            $0.uuid = .constant(installID)
        }

        await store.send(.installAPK(data: Data([1, 2, 3]), fileName: "test.apk")) {
            $0.isInstalling = true
            $0.installProgress = "Pushing test.apk to device..."
            $0.errorMessage = nil
            $0.activeInstallID = installID
            $0.activeInstallRemotePath = remotePath
        }

        await store.receive(\.installProgressChanged) {
            $0.installProgress = "Installing APK..."
        }

        await store.receive(\.installSucceeded) {
            $0.isInstalling = false
            $0.installProgress = ""
            $0.activeInstallID = nil
            $0.activeInstallRemotePath = nil
            $0.statusMessage = "Success"
        }

        await store.receive(\.loadApps) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.appsLoaded.success) {
            $0.isLoading = false
        }
    }

    @Test
    func installAPKStreamsSelectedFile() async {
        let localURL = URL(fileURLWithPath: "/tmp/large.apk")
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
        let remotePath = "/data/local/tmp/iadb-upload-\(installID.uuidString).apk"
        let receivedURL = LockIsolated<URL?>(nil)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.pushFile = { url, _, _ in receivedURL.setValue(url) }
            $0.adbClient.shell = { _ in "Success" }
            $0.adbClient.listPackages = { _ in [] }
            $0.uuid = .constant(installID)
        }

        await store.send(.installAPKFile(url: localURL, fileName: "large.apk")) {
            $0.isInstalling = true
            $0.installProgress = "Pushing large.apk to device..."
            $0.errorMessage = nil
            $0.activeInstallID = installID
            $0.activeInstallRemotePath = remotePath
        }
        await store.receive(\.installProgressChanged) {
            $0.installProgress = "Installing APK..."
        }
        await store.receive(\.installSucceeded) {
            $0.isInstalling = false
            $0.installProgress = ""
            $0.activeInstallID = nil
            $0.activeInstallRemotePath = nil
            $0.statusMessage = "Success"
        }
        await store.receive(\.loadApps) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.appsLoaded.success) {
            $0.isLoading = false
        }

        #expect(receivedURL.value == localURL)
    }

    @Test
    func cancelInstallRestoresUIAndCleansTemporaryAPK() async {
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000053")!
        let remotePath = "/data/local/tmp/iadb-upload-\(installID.uuidString).apk"
        let cleanupCommand = LockIsolated<String?>(nil)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.pushFile = { _, _, _ in
                try await Task.sleep(for: .seconds(60))
            }
            $0.adbClient.shell = { command in
                cleanupCommand.setValue(command)
                return ""
            }
            $0.uuid = .constant(installID)
        }

        await store.send(.installAPKFile(
            url: URL(fileURLWithPath: "/tmp/large.apk"),
            fileName: "large.apk"
        )) {
            $0.isInstalling = true
            $0.installProgress = "Pushing large.apk to device..."
            $0.errorMessage = nil
            $0.activeInstallID = installID
            $0.activeInstallRemotePath = remotePath
        }
        await store.send(.cancelInstall) {
            $0.isInstalling = false
            $0.installProgress = ""
            $0.activeInstallID = nil
            $0.activeInstallRemotePath = nil
        }
        await store.finish()

        #expect(cleanupCommand.value == "rm -f '\(remotePath)'")
    }

    @Test
    func failedInstallCleansTemporaryAPKAndShowsError() async {
        let installID = UUID(uuidString: "00000000-0000-0000-0000-000000000054")!
        let remotePath = "/data/local/tmp/iadb-upload-\(installID.uuidString).apk"
        let cleanupCommand = LockIsolated<String?>(nil)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.pushFile = { _, _, _ in }
            $0.adbClient.shell = { command in
                if command.hasPrefix("pm install") {
                    throw ADBError.commandFailed("INSTALL_FAILED_INVALID_APK")
                }
                cleanupCommand.setValue(command)
                return ""
            }
            $0.uuid = .constant(installID)
        }

        await store.send(.installAPKFile(
            url: URL(fileURLWithPath: "/tmp/broken.apk"),
            fileName: "broken.apk"
        )) {
            $0.isInstalling = true
            $0.installProgress = "Pushing broken.apk to device..."
            $0.errorMessage = nil
            $0.activeInstallID = installID
            $0.activeInstallRemotePath = remotePath
        }
        await store.receive(\.installProgressChanged) {
            $0.installProgress = "Installing APK..."
        }
        await store.receive(\.installFailed) {
            $0.isInstalling = false
            $0.installProgress = ""
            $0.activeInstallID = nil
            $0.activeInstallRemotePath = nil
            $0.errorMessage = ADBError.commandFailed("INSTALL_FAILED_INVALID_APK").localizedDescription
        }

        #expect(store.state.isInstalling == false)
        #expect(store.state.errorMessage?.contains("INSTALL_FAILED_INVALID_APK") == true)
        #expect(cleanupCommand.value == "rm -f '\(remotePath)'")
    }

    @Test
    func staleInstallCompletionCannotOverwriteNewInstallState() async {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000056")!
        let store = TestStore(initialState: AppsFeature.State(
            isInstalling: true,
            installProgress: "Pushing current.apk to device...",
            activeInstallID: currentID,
            activeInstallRemotePath: "/data/local/tmp/current.apk"
        )) {
            AppsFeature()
        }

        await store.send(.installSucceeded(id: oldID, result: "Success"))
        #expect(store.state.activeInstallID == currentID)
        #expect(store.state.isInstalling)
        #expect(store.state.statusMessage == nil)
    }
}
