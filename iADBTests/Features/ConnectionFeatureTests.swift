import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct ConnectionFeatureTests {
    @Test
    func onAppearStartsDiscovery() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.load = { [] }
            $0.deviceDiscoveryClient.start = { _ in
                AsyncStream { $0.yield([]); $0.finish() }
            }
        }

        await store.send(.onAppear)
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.isScanning = false
        }
    }

    @Test
    func connectToDeviceSuccess() async {
        let device = DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in "device::Pixel" }
        }

        await store.send(.connectToDevice(device)) {
            $0.connectionState = .connecting
            $0.lastConnectionDevice = device
        }
        await store.receive(\.connectionResult.success) {
            $0.connectionState = .connected
        }
    }

    @Test
    func connectToDeviceError() async {
        let device = DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in throw ADBError.connectionFailed("timeout") }
        }

        await store.send(.connectToDevice(device)) {
            $0.connectionState = .connecting
            $0.lastConnectionDevice = device
        }
        await store.receive(\.connectionResult.failure) {
            $0.connectionState = .error("Connection failed: timeout")
            $0.lastConnectionError = "Connection failed: timeout"
        }
    }

    @Test
    func disconnect() async {
        var disconnected = false
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connected)
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected = true }
        }

        await store.send(.disconnect) {
            $0.connectionState = .disconnected
        }
        #expect(disconnected)
    }

    @Test
    func showManualPairing() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showManualPairing) {
            $0.pairing = PairingFeature.State()
        }
    }

    @Test
    func showPairingForDeviceWithPairingPort() async {
        let device = DiscoveredDevice(id: "test", name: "Galaxy", host: "10.0.0.5", port: 42100, isPaired: false, pairingPort: 37000)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showPairingForDevice(device)) {
            $0.pairing = PairingFeature.State(
                hostInput: "10.0.0.5",
                portInput: "37000",
                isPrefilled: true,
                serviceName: "test"
            )
        }
    }

    @Test
    func showPairingForDeviceWithoutPairingPort() async {
        let device = DiscoveredDevice(id: "test", name: "Galaxy", host: "10.0.0.5", port: 42100, isPaired: false)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showPairingForDevice(device)) {
            $0.pairing = PairingFeature.State(
                hostInput: "10.0.0.5",
                serviceName: "test"
            )
        }
    }

    @Test
    func reconnectLastDevice() async {
        let device = DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
        let store = TestStore(
            initialState: ConnectionFeature.State(lastConnectionDevice: device)
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in "device::Pixel" }
        }

        await store.send(.reconnectLastDevice)
        await store.receive(\.connectToDevice) {
            $0.connectionState = .connecting
            $0.lastConnectionDevice = device
        }
        await store.receive(\.connectionResult.success) {
            $0.connectionState = .connected
        }
    }

    @Test
    func rescanClearsVisibleDevicesAndRestartsDiscovery() async {
        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)],
                lastConnectionError: "Connection failed"
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.deviceDiscoveryClient.start = { _ in
                AsyncStream { continuation in
                    continuation.yield([])
                    continuation.finish()
                }
            }
        }

        await store.send(.rescan) {
            $0.discoveredDevices = []
            $0.lastConnectionError = nil
        }
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.isScanning = false
        }
    }

    @Test
    func duplicateConnectIgnored() async {
        let device = DiscoveredDevice(id: "test", name: "P", host: "1.2.3.4", port: 5555, isPaired: true)
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connecting)
        ) {
            ConnectionFeature()
        }

        await store.send(.connectToDevice(device))
    }

    @Test
    func devicesUpdatedMatchesPaired() async {
        let paired = PairedDevice(name: "My Pixel", publicKey: Data([1]), lastHost: "10.0.0.1")
        let discovered = [DiscoveredDevice(id: "s1", name: "adb-abc", host: "10.0.0.1", port: 38745, isPaired: false)]

        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [paired])
        ) {
            ConnectionFeature()
        }

        await store.send(.devicesUpdated(discovered)) {
            $0.discoveredDevices = [
                DiscoveredDevice(id: "s1", name: "My Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
            ]
        }
    }

    #if DEBUG
    @Test
    func debugSettingsModalIsHiddenUntilLongPressReveal() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        #expect(store.state.debugSettingsPresented == false)

        await store.send(.showDebugSettings) {
            $0.debugSettingsPresented = true
        }
    }

    @Test
    func debugAndroidEmulatorDiscoveryUsesConfiguredEndpoint() async {
        let settings = DebugSettings(
            useAndroidEmulator: true,
            emulatorHost: "127.0.0.1",
            emulatorPortInput: "5555"
        )
        let expectedDevice = DiscoveredDevice(
            id: "debug-android-emulator",
            name: "Android Emulator",
            host: "127.0.0.1",
            port: 5555,
            isPaired: true
        )

        let store = TestStore(
            initialState: ConnectionFeature.State(debugSettings: settings)
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.debugEmulatorClient.isAvailable = { host, port in
                #expect(host == "127.0.0.1")
                #expect(port == 5555)
                return true
            }
        }

        await store.send(.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = [expectedDevice]
            $0.isScanning = false
        }
    }

    @Test
    func debugAndroidEmulatorDiscoveryStaysEmptyWhenEndpointIsUnavailable() async {
        let settings = DebugSettings(
            useAndroidEmulator: true,
            emulatorHost: "127.0.0.1",
            emulatorPortInput: "5555"
        )

        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [
                    DiscoveredDevice(id: "old", name: "Old", host: "127.0.0.1", port: 5555, isPaired: true)
                ],
                debugSettings: settings
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.debugEmulatorClient.isAvailable = { _, _ in false }
        }

        await store.send(.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = []
            $0.isScanning = false
        }
    }

    @Test
    func debugSettingsTogglePersistsAndRestartsDiscoveryImmediately() async {
        let expectedSettings = DebugSettings(
            useAndroidEmulator: true,
            emulatorHost: "127.0.0.1",
            emulatorPortInput: "5555"
        )
        let expectedDevice = DiscoveredDevice(
            id: "debug-android-emulator",
            name: "Android Emulator",
            host: "127.0.0.1",
            port: 5555,
            isPaired: true
        )
        var savedSettings: DebugSettings?

        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [
                    DiscoveredDevice(id: "old", name: "Old", host: "10.0.0.1", port: 5555, isPaired: false)
                ],
                lastConnectionError: "old error",
                debugSettingsPresented: true
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.debugSettingsClient.save = { savedSettings = $0 }
            $0.debugEmulatorClient.isAvailable = { _, _ in true }
        }

        await store.send(.binding(.set(\.debugSettings.useAndroidEmulator, true))) {
            $0.debugSettings.useAndroidEmulator = true
        }
        await store.receive(\.debugSettingsChanged) {
            $0.discoveredDevices = []
            $0.lastConnectionError = nil
        }
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = [expectedDevice]
            $0.isScanning = false
        }

        #expect(savedSettings == expectedSettings)
    }

    @Test
    func debugSettingsFieldChangePersistsSanitizesAndRestartsDiscoveryImmediately() async {
        let initialSettings = DebugSettings(
            useAndroidEmulator: true,
            emulatorHost: "10.0.0.1",
            emulatorPortInput: "1234"
        )
        let expectedSettings = DebugSettings(
            useAndroidEmulator: true,
            emulatorHost: "127.0.0.1",
            emulatorPortInput: "5555"
        )
        let expectedDevice = DiscoveredDevice(
            id: "debug-android-emulator",
            name: "Android Emulator",
            host: "127.0.0.1",
            port: 5555,
            isPaired: true
        )
        var savedSettings: DebugSettings?

        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [
                    DiscoveredDevice(id: "old", name: "Old", host: "10.0.0.1", port: 5555, isPaired: false)
                ],
                lastConnectionError: "old error",
                debugSettings: initialSettings,
                debugSettingsPresented: true
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.debugSettingsClient.save = { savedSettings = $0 }
            $0.debugEmulatorClient.isAvailable = { _, _ in true }
        }

        await store.send(.binding(.set(\.debugSettings.emulatorHost, "  127.0.0.1  "))) {
            $0.debugSettings.emulatorHost = "  127.0.0.1  "
        }
        await store.receive(\.debugSettingsChanged) {
            $0.discoveredDevices = []
            $0.lastConnectionError = nil
        }
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = [
                DiscoveredDevice(
                    id: "debug-android-emulator",
                    name: "Android Emulator",
                    host: "127.0.0.1",
                    port: 1234,
                    isPaired: true
                )
            ]
            $0.isScanning = false
        }

        await store.send(.binding(.set(\.debugSettings.emulatorPortInput, "not-a-port"))) {
            $0.debugSettings.emulatorPortInput = "not-a-port"
        }
        await store.receive(\.debugSettingsChanged) {
            $0.discoveredDevices = []
        }
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = [expectedDevice]
            $0.isScanning = false
        }

        #expect(savedSettings == expectedSettings)
    }

    @Test
    func debugSettingsCanBeSeededFromLaunchEnvironment() {
        let settings = DebugSettings.resolved(
            stored: .defaultValue,
            arguments: ["iADB", "--iadb-debug-android-emulator"],
            environment: [
                "IADB_DEBUG_ANDROID_HOST": "10.0.2.2",
                "IADB_DEBUG_ANDROID_PORT": "5556"
            ]
        )

        #expect(settings.useAndroidEmulator)
        #expect(settings.emulatorHost == "10.0.2.2")
        #expect(settings.emulatorPortInput == "5556")
    }
    #endif
}
