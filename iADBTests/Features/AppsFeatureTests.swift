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
        let store = TestStore(
            initialState: AppsFeature.State(apps: [app])
        ) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.uninstallPackage = { _, _ in "Success" }
            $0.adbClient.listPackages = { _ in [] }
        }

        await store.send(.uninstall(app, keepData: false))

        await store.receive(\.operationResult.success) {
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
        var stoppedPackage: String?
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.forceStopApp = { name in stoppedPackage = name }
        }

        await store.send(.forceStop(app))
        await store.receive(\.operationResult.success) {
            $0.statusMessage = "Force stopped com.test.app"
        }
        #expect(stoppedPackage == "com.test.app")
    }

    @Test
    func clearDataSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.clearAppData = { _ in "Success" }
        }

        await store.send(.clearData(app))
        await store.receive(\.operationResult.success) {
            $0.statusMessage = "Success"
        }
    }

    @Test
    func getAppDetailSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.getAppInfo = { _ in "versionName=1.0\nversionCode=42\ntargetSdk=34\nfirstInstallTime=2024-01-01\nlastUpdateTime=2024-01-02\npkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]" }
        }

        await store.send(.getAppDetail(app)) {
            $0.selectedApp = app
        }
        await store.receive(\.appDetailLoaded.success) {
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
    func launchAppSuccess() async {
        let app = AppInfo(packageName: "com.test.app", isSystemApp: false)
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "Events injected: 1" }
        }

        await store.send(.launchApp(app))
        await store.receive(\.operationResult.success) {
            $0.statusMessage = "Launched com.test.app"
        }
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
        let store = TestStore(initialState: AppsFeature.State()) {
            AppsFeature()
        } withDependencies: {
            $0.adbClient.pushData = { _, _, _ in }
            $0.adbClient.shell = { _ in "Success" }
            $0.adbClient.listPackages = { _ in [] }
        }

        await store.send(.installAPK(data: Data([1, 2, 3]), fileName: "test.apk")) {
            $0.isInstalling = true
            $0.installProgress = "Pushing APK to device..."
            $0.errorMessage = nil
        }

        await store.receive(\.installResult.success) {
            $0.isInstalling = false
            $0.installProgress = ""
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
}
