import ComposableArchitecture
import Testing
@testable import iADB

@MainActor
struct AppFeatureTests {
    @Test
    func selectTab() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.selectTab(.device)) {
            $0.selectedTab = .device
        }
    }

    @Test
    func connectionSuccessTriggersChildFetches() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.getDeviceProperty = { _ in "" }
            $0.adbClient.getAndroidVersion = { "" }
            $0.adbClient.getSDKVersion = { "" }
            $0.adbClient.getDeviceSerial = { "" }
            $0.adbClient.getBatteryLevel = { "" }
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.listDirectory = { _ in "" }
            $0.adbClient.listPackages = { _ in [] }
        }

        store.exhaustivity = .off

        await store.send(.connection(.connectionResult(.success("banner")))) {
            $0.connection.connectionState = .connected
        }

        // Should receive fetch actions for device, fileManager, apps
        await store.receive(\.device.fetchDeviceInfo)
        await store.receive(\.fileManager.loadDirectory)
        await store.receive(\.apps.loadApps)

        // Let all effects complete
        await store.skipReceivedActions()
    }

    @Test
    func disconnectResetsChildStates() async {
        var state = AppFeature.State()
        state.device.details.model = "Pixel"
        state.apps.apps = [AppInfo(packageName: "com.test", isSystemApp: false)]
        state.shell.history = [ShellHistoryEntry(command: "ls", output: ".", timestamp: Date(), isError: false)]
        state.connection.connectionState = .connected

        var disconnected = false
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected = true }
        }

        await store.send(.connection(.disconnect)) {
            $0.connection.connectionState = .disconnected
            $0.device = DeviceInfoFeature.State()
            $0.apps = AppsFeature.State()
            $0.fileManager = FileManagerFeature.State()
            $0.shell = ShellFeature.State()
            $0.logcat = LogcatFeature.State()
            $0.screenshot = ScreenshotFeature.State()
        }
        #expect(disconnected)
    }
}
