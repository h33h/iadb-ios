import ComposableArchitecture
import Foundation
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
        var state = AppFeature.State()
        state.connection.connectionState = .connecting
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.getDeviceProperty = { _ in "" }
            $0.adbClient.getAndroidVersion = { "" }
            $0.adbClient.getSDKVersion = { "" }
            $0.adbClient.getDeviceSerial = { "" }
            $0.adbClient.getBatteryLevel = { "" }
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.adbClient.listPackages = { _ in [] }
        }

        store.exhaustivity = .off

        await store.send(.connection(.connectionResult(generation: 1, .success("banner")))) {
            $0.connection.connectionState = .connected
        }

        await store.receive(\.device.fetchDeviceInfo)
        await store.receive(\.fileManager.loadDirectory)
        await store.receive(\.apps.loadApps)

        await store.skipReceivedActions()
    }

    @Test
    func disconnectResetsChildStates() async {
        var state = AppFeature.State()
        state.device.details.model = "Pixel"
        state.apps.apps = [AppInfo(packageName: "com.test", isSystemApp: false)]
        state.shell.history = [ShellHistoryEntry(command: "ls", output: ".", timestamp: Date(), isError: false)]
        state.connection.connectionState = .connected
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1

        let disconnected = LockIsolated(false)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        store.exhaustivity = .off
        await store.send(.connection(.disconnect)) {
            $0.connection.connectionState = .disconnected
            $0.connection.activeConnectionGeneration = nil
        }
        await store.skipReceivedActions()
        store.exhaustivity = .on
        #expect(store.state.device == DeviceInfoFeature.State())
        #expect(store.state.apps == AppsFeature.State())
        #expect(store.state.shell == ShellFeature.State())
        #expect(disconnected.value)
    }

    @Test
    func connectionLossReturnsToConnectAndClearsDeviceData() async {
        var state = AppFeature.State()
        state.selectedTab = .files
        state.connection.connectionState = .connected
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        state.device.details.model = "Pixel"
        state.shell.history = [
            ShellHistoryEntry(command: "pwd", output: "/", timestamp: Date(), isError: false)
        ]
        let disconnected = LockIsolated(false)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        store.exhaustivity = .off
        await store.send(.connection(.connectionLost(generation: 1, "Connection lost"))) {
            $0.connection.connectionState = .error("Connection lost")
            $0.connection.lastConnectionError = "Connection lost"
            $0.connection.activeConnectionGeneration = nil
        }
        await store.skipReceivedActions()
        store.exhaustivity = .on
        #expect(store.state.selectedTab == .connection)
        #expect(store.state.device == DeviceInfoFeature.State())
        #expect(disconnected.value)
    }

    @Test
    func tappingAnotherDeviceWhileConnectedCannotMixChildDeviceState() async {
        let current = DiscoveredDevice(
            id: "pixel-a",
            name: "Pixel A",
            host: "192.168.1.20",
            port: 37777,
            isPaired: true
        )
        let other = DiscoveredDevice(
            id: "pixel-b",
            name: "Pixel B",
            host: "192.168.1.21",
            port: 38888,
            isPaired: true
        )
        var state = AppFeature.State()
        state.connection.connectionState = .connected
        state.connection.lastConnectionDevice = current
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        state.device.details.model = "Pixel A"
        state.fileManager.currentPath = "/sdcard/A"
        state.shell.isExecuting = true
        let connectCalls = LockIsolated(0)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in
                connectCalls.withValue { $0 += 1 }
                return "unexpected"
            }
        }

        await store.send(.connection(.connectToDevice(other))) {
            $0.connection.lastConnectionError =
                "Disconnect the current device before connecting to another one."
        }

        #expect(store.state.connection.connectionState == .connected)
        #expect(store.state.connection.lastConnectionDevice == current)
        #expect(store.state.device.details.model == "Pixel A")
        #expect(store.state.fileManager.currentPath == "/sdcard/A")
        #expect(store.state.shell.isExecuting)
        #expect(connectCalls.value == 0)
    }

    @Test
    func successfulRebootTransitionsToReconnectState() async {
        var state = AppFeature.State()
        state.selectedTab = .device
        state.connection.connectionState = .connected
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        state.connection.lastConnectionDevice = DiscoveredDevice(
            id: "pixel",
            name: "Pixel",
            host: "192.168.1.20",
            port: 38888,
            isPaired: true
        )
        let disconnected = LockIsolated(false)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        store.exhaustivity = .off
        await store.send(.device(.rebootResult(.success(())))) {
            $0.device.rebootStatusMessage = "Reboot command sent. Waiting for the device to come back online…"
        }
        await store.receive(\.connection.connectionLost) {
            $0.connection.connectionState = .error(
                "The Android device is rebooting. Wait until Wireless debugging is available, then tap Reconnect or Rescan."
            )
            $0.connection.lastConnectionError =
                "The Android device is rebooting. Wait until Wireless debugging is available, then tap Reconnect or Rescan."
            $0.connection.activeConnectionGeneration = nil
        }
        await store.skipReceivedActions()
        store.exhaustivity = .on
        #expect(store.state.selectedTab == .connection)
        #expect(store.state.device == DeviceInfoFeature.State())

        #expect(disconnected.value)
    }
}
