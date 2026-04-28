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
            $0.adbClient.getAppInfo = { _ in "Package: com.test.app\nVersion: 1.0" }
        }

        await store.send(.getAppDetail(app)) {
            $0.selectedApp = app
        }
        await store.receive(\.appDetailLoaded.success) {
            $0.appDetailText = "Package: com.test.app\nVersion: 1.0"
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
        } withDependencies: {
            $0.adbClient.listPackages = { _ in [] }
        }

        await store.send(.toggleSystemApps) {
            $0.showSystemApps = true
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
                AppInfo(packageName: "com.google.maps", isSystemApp: false)
            ],
            searchText: "google"
        )
        #expect(state.filteredApps.count == 2)
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
