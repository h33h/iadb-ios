import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct AppFeatureTests {
    @Test
    func connectionSetupGateOpensBeforeTheWorkspace() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        #expect(!store.state.hasEnteredWorkspace)
        #expect(!store.state.isConnectionSetupPresented)

        await store.send(.showConnectionSetup) {
            $0.isConnectionSetupPresented = true
        }
    }

    @Test
    func workspaceSelectionsAreMirroredIntoAppShellAndSurviveRootSwitch() async {
        let file = FileEntry(
            name: "report.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "shell",
            size: "42",
            date: "2026-07-13",
            time: "12:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/Download/report.txt"
        )
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.fileManager(.selectFile(file))) {
            $0.fileManager.selectedFile = file
            $0.fileManager.showingFileActions = true
            $0.appShell.detailSelections[.files] = .file(path: file.fullPath)
        }
        await store.send(.appShell(.selectRoot(.apps))) {
            $0.appShell.selectedRoot = .apps
        }
        await store.send(.appShell(.selectRoot(.files))) {
            $0.appShell.selectedRoot = .files
        }
        #expect(store.state.fileManager.selectedFile == file)
        #expect(store.state.appShell.detailSelection(for: .files) == .file(path: file.fullPath))
    }

    @Test
    func selectTab() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.selectTab(.files)) {
            $0.appShell.selectedRoot = .files
        }
    }

    @Test
    func connectionSuccessTriggersChildFetches() async {
        var state = AppFeature.State()
        state.connection.connectionState = .connecting
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        state.isConnectionSetupPresented = true
        state.connection.lastConnectionDevice = DiscoveredDevice(
            id: "pixel",
            name: "Pixel",
            host: "192.0.2.10",
            port: 37141,
            isPaired: true
        )
        state.shell.commandInput = "reboot"
        state.shell.draftsByDeviceID[DeviceIdentity.unknownID] = "reboot"
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 100))
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
            $0.hasEnteredWorkspace = true
            $0.isConnectionSetupPresented = false
        }

        await store.receive(\.session.connectionSucceeded)
        await store.receive(\.device.fetchDeviceInfo)
        await store.receive(\.fileManager.loadDirectory)
        await store.receive(\.apps.loadApps)

        await store.skipReceivedActions()
        #expect(store.state.shell.commandInput == "reboot")
        #expect(store.state.shell.isExecuting == false)
        #expect(store.state.shell.history.isEmpty)
    }

    @Test
    func disconnectPreservesWorkspaceContextAndMarksSnapshotsStale() async {
        var state = AppFeature.State()
        state.hasEnteredWorkspace = true
        state.selectedTab = .files
        state.device.details.model = "Pixel"
        state.apps.apps = [AppInfo(packageName: "com.test", isSystemApp: false)]
        state.apps.searchText = "test"
        state.fileManager.currentPath = "/sdcard/Download"
        state.fileManager.pathHistory = ["/sdcard", "/sdcard/Download"]
        state.shell.commandInput = "getprop"
        state.shell.history = [ShellHistoryEntry(command: "ls", output: ".", timestamp: Date(), isError: false)]
        state.logcat.entries = [
            LogEntry(timestamp: "07-12 09:41:16.204", pid: "1", tid: "1", level: .info, tag: "Demo", message: "retained")
        ]
        let identity = DeviceIdentity(stableID: "guid:pixel", displayName: "Pixel", adbFingerprint: "pixel")
        state.session.selectedDevice = identity
        state.session.transport = .connected(
            endpoint: Endpoint(host: "192.0.2.1", port: 37141),
            since: Date(timeIntervalSince1970: 100)
        )
        state.session.capabilities = .connected
        state.session.remoteSnapshots[.files] = RemoteSnapshotRelationship(
            deviceID: identity.stableID,
            fetchedAt: Date(timeIntervalSince1970: 100),
            isStale: false
        )
        state.connection.connectionState = .connected
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1

        let disconnected = LockIsolated(false)
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 200))
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        store.exhaustivity = .off
        await store.send(.connection(.disconnect)) {
            $0.connection.connectionState = .disconnected
            $0.connection.activeConnectionGeneration = nil
        }
        await store.skipReceivedActions()
        store.exhaustivity = .on
        #expect(store.state.selectedTab == .files)
        #expect(store.state.hasEnteredWorkspace)
        #expect(store.state.device.details.model == "Pixel")
        #expect(store.state.apps.apps.count == 1)
        #expect(store.state.apps.searchText == "test")
        #expect(store.state.fileManager.currentPath == "/sdcard/Download")
        #expect(store.state.shell.commandInput == "getprop")
        #expect(store.state.shell.history.count == 1)
        #expect(store.state.logcat.entries.count == 1)
        #expect(store.state.session.capabilities == .offline)
        #expect(store.state.session.remoteSnapshots[.files]?.isStale == true)
        #expect(disconnected.value)
    }

    @Test
    func connectionLossKeepsCurrentRootAndLastKnownData() async {
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
            $0.date = .constant(Date(timeIntervalSince1970: 200))
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
        #expect(store.state.selectedTab == .files)
        #expect(store.state.device.details.model == "Pixel")
        #expect(store.state.shell.history.count == 1)
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
            $0.date = .constant(Date(timeIntervalSince1970: 200))
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
        #expect(store.state.selectedTab == .device)
        #expect(store.state.connection.lastConnectionDevice?.id == "pixel")

        #expect(disconnected.value)
    }
}
