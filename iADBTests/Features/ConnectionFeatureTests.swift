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
                AsyncStream { $0.yield(.devices([])); $0.finish() }
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
            $0.connectionGeneration = 1
            $0.activeConnectionGeneration = 1
        }
        await store.receive(\.connectionResult) {
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
            $0.connectionGeneration = 1
            $0.activeConnectionGeneration = 1
        }
        await store.receive(\.connectionResult) {
            $0.connectionState = .error("Connection failed: timeout")
            $0.lastConnectionError = "Connection failed: timeout"
            $0.activeConnectionGeneration = nil
        }
    }

    @Test
    func disconnect() async {
        let disconnected = LockIsolated(false)
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connected)
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        await store.send(.disconnect) {
            $0.connectionState = .disconnected
        }
        #expect(disconnected.value)
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
            $0.connectionGeneration = 1
            $0.activeConnectionGeneration = 1
        }
        await store.receive(\.connectionResult) {
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
                    continuation.yield(.devices([]))
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
    func legacySavedDeviceDoesNotClaimAReusedIPAddress() async {
        let paired = PairedDevice(name: "My Pixel", publicKey: Data([1]), lastHost: "10.0.0.1")
        let discovered = [DiscoveredDevice(id: "s1", name: "adb-abc", host: "10.0.0.1", port: 38745, isPaired: false)]

        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [paired])
        ) {
            ConnectionFeature()
        }

        await store.send(.devicesUpdated(discovered)) {
            $0.discoveredDevices = discovered
        }

        #expect(store.state.offlinePairedDevices == [paired])
    }

    @Test
    func manuallyPairedGuidMatchesDiscoveryAfterIPAddressChanges() async {
        let paired = PairedDevice(
            name: "My Pixel",
            guid: "adb-device-guid",
            lastHost: "10.0.0.10"
        )
        let discovered = DiscoveredDevice(
            id: "adb-device-guid",
            name: "adb-device-guid",
            host: "10.0.0.42",
            port: 38888,
            isPaired: false
        )
        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [paired])
        ) {
            ConnectionFeature()
        }

        await store.send(.devicesUpdated([discovered])) {
            $0.discoveredDevices = [DiscoveredDevice(
                id: "adb-device-guid",
                name: "My Pixel",
                host: "10.0.0.42",
                port: 38888,
                isPaired: true
            )]
            $0.isScanning = false
        }

        #expect(store.state.offlinePairedDevices.isEmpty)
    }

    @Test
    func exactGUIDMatchWinsOverAnotherDevicesLegacyHostFallback() async {
        let legacy = PairedDevice(
            name: "Legacy Pixel",
            guid: "legacy-guid",
            lastHost: "192.168.1.42"
        )
        let exact = PairedDevice(
            name: "Current Galaxy",
            guid: "galaxy-guid",
            lastHost: "192.168.1.99"
        )
        let discovered = DiscoveredDevice(
            id: "galaxy-guid",
            name: "adb-galaxy",
            host: "192.168.1.42",
            port: 38888,
            isPaired: false
        )
        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [legacy, exact])
        ) {
            ConnectionFeature()
        }

        await store.send(.devicesUpdated([discovered])) {
            $0.discoveredDevices = [DiscoveredDevice(
                id: "galaxy-guid",
                name: "Current Galaxy",
                host: "192.168.1.42",
                port: 38888,
                isPaired: true
            )]
            $0.isScanning = false
        }

        #expect(store.state.offlinePairedDevices == [legacy])
    }

    @Test
    func forgettingHostCollisionDoesNotForgetExactCurrentDevice() async {
        let legacy = PairedDevice(
            name: "Legacy Pixel",
            guid: "legacy-guid",
            lastHost: "192.168.1.42"
        )
        let exact = PairedDevice(
            name: "Current Galaxy",
            guid: "galaxy-guid",
            lastHost: "192.168.1.99"
        )
        let discovered = DiscoveredDevice(
            id: "galaxy-guid",
            name: "Current Galaxy",
            host: "192.168.1.42",
            port: 38888,
            isPaired: true
        )
        let savedDevices = LockIsolated<[PairedDevice]>([legacy, exact])
        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [discovered],
                pairedDevices: [legacy, exact],
                connectionState: .connected,
                lastConnectionDevice: discovered,
                pendingForgetDeviceID: legacy.id
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
        }

        await store.send(.confirmForgetPairedDevice) {
            $0.pairedDevices = [exact]
            $0.pendingForgetDeviceID = nil
        }
        await store.finish()

        #expect(store.state.connectionState == .connected)
        #expect(store.state.lastConnectionDevice == discovered)
        #expect(store.state.discoveredDevices == [discovered])
        #expect(savedDevices.value == [exact])
    }

    @Test
    func discoveryFailureStopsSpinnerAndProvidesRecovery() async {
        let message = "Local Network access is disabled."
        let store = TestStore(
            initialState: ConnectionFeature.State(isScanning: true)
        ) {
            ConnectionFeature()
        }

        await store.send(.discoveryEvent(.failure(message))) {
            $0.isScanning = false
            $0.discoveryError = message
        }
        await store.send(.discoveryEvent(.ready)) {
            $0.discoveryError = nil
        }
    }

    @Test
    func discoveryCompletionWithoutEventsStopsSpinner() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.deviceDiscoveryClient.start = { _ in
                AsyncStream { $0.finish() }
            }
        }

        await store.send(.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.discoveryStopped) {
            $0.isScanning = false
        }
    }

    @Test
    func cancelConnectionReturnsToDisconnectedAndIgnoresLateResult() async {
        let device = DiscoveredDevice(
            id: "pixel",
            name: "Pixel",
            host: "192.168.1.20",
            port: 37777,
            isPaired: true
        )
        let disconnected = LockIsolated(false)
        let store = TestStore(
            initialState: ConnectionFeature.State(
                connectionState: .connecting,
                lastConnectionDevice: device,
                connectionGeneration: 1,
                activeConnectionGeneration: 1
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        await store.send(.cancelConnection) {
            $0.connectionState = .disconnected
            $0.activeConnectionGeneration = nil
        }
        #expect(disconnected.value)

        await store.send(.connectionResult(generation: 1, .success("late banner")))
    }

    @Test
    func connectionLossSetsRecoverableErrorAndDisconnectsClient() async {
        let disconnected = LockIsolated(false)
        let store = TestStore(
            initialState: ConnectionFeature.State(
                connectionState: .connected,
                connectionGeneration: 1,
                activeConnectionGeneration: 1
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        await store.send(.connectionLost(generation: 1, "Wi-Fi connection was lost")) {
            $0.connectionState = .error("Wi-Fi connection was lost")
            $0.lastConnectionError = "Wi-Fi connection was lost"
            $0.activeConnectionGeneration = nil
        }
        #expect(disconnected.value)
    }

    @Test
    func savedOfflineDeviceCanUseCurrentWirelessDebuggingEndpoint() async {
        let paired = PairedDevice(
            name: "Pixel",
            guid: "pixel-guid",
            lastHost: "192.168.1.10"
        )
        let endpoint = DiscoveredDevice(
            id: "pixel-guid",
            name: "Pixel",
            host: "192.168.1.42",
            port: 38888,
            isPaired: true
        )
        let disconnected = LockIsolated(false)
        let savedDevices = LockIsolated<[PairedDevice]>([])
        let store = TestStore(
            initialState: ConnectionFeature.State(
                pairedDevices: [paired],
                manualConnection: ConnectionFeature.ManualConnection(
                    pairedDeviceID: paired.id,
                    deviceName: "Pixel",
                    hostInput: "192.168.1.42",
                    portInput: "٣٨٨٨٨"
                )
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
            $0.adbClient.connect = { host, port in
                #expect(host == "192.168.1.42")
                #expect(port == 38888)
                return "device::Pixel"
            }
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        await store.send(.connectManualEndpoint) {
            $0.pairedDevices[0].lastHost = "192.168.1.42"
            $0.manualConnection = nil
        }
        await store.receive(\.connectToDevice) {
            $0.connectionState = .connecting
            $0.lastConnectionDevice = endpoint
            $0.connectionGeneration = 1
            $0.activeConnectionGeneration = 1
        }
        await store.receive(\.connectionResult) {
            $0.connectionState = .connected
        }

        #expect(savedDevices.value.first?.lastHost == "192.168.1.42")

        await store.send(.requestForgetPairedDevice(id: paired.id)) {
            $0.pendingForgetDeviceID = paired.id
        }
        await store.send(.confirmForgetPairedDevice) {
            $0.pairedDevices = []
            $0.lastConnectionDevice = nil
            $0.pendingForgetDeviceID = nil
        }
        await store.receive(\.disconnect) {
            $0.connectionState = .disconnected
            $0.activeConnectionGeneration = nil
        }

        #expect(disconnected.value)
        #expect(savedDevices.value.isEmpty)
    }

    @Test
    func manualPairingAlwaysLeavesAnExplicitConnectStep() async {
        let didConnect = LockIsolated(false)
        let savedDevices = LockIsolated<[PairedDevice]>([])
        let reusedHostDevice = DiscoveredDevice(
            id: "different-device-guid",
            name: "Different Device",
            host: "192.168.1.42",
            port: 38888,
            isPaired: false
        )
        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [reusedHostDevice],
                pairing: PairingFeature.State(
                    hostInput: "192.168.1.42",
                    portInput: "37123",
                    pairingCode: "123456"
                )
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
            $0.adbClient.connect = { _, _ in
                didConnect.setValue(true)
                return "device::Wrong"
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(
            .pairing(
                .presented(
                    .pairingCompleted(name: "Pixel", guid: "pixel-guid")
                )
            )
        )
        await store.skipReceivedActions()

        #expect(store.state.manualConnection?.hostInput == "192.168.1.42")
        #expect(store.state.manualConnection?.portInput == "")
        #expect(savedDevices.value.first?.name == "Pixel")
        #expect(!didConnect.value)
    }

    @Test
    func manualConnectionRejectsPairingPortPlaceholder() async {
        let paired = PairedDevice(name: "Pixel", publicKey: Data([1]), lastHost: "192.168.1.10")
        let store = TestStore(
            initialState: ConnectionFeature.State(
                pairedDevices: [paired],
                manualConnection: ConnectionFeature.ManualConnection(
                    pairedDeviceID: paired.id,
                    deviceName: "Pixel",
                    hostInput: "192.168.1.10",
                    portInput: "not-a-port"
                )
            )
        ) {
            ConnectionFeature()
        }

        await store.send(.connectManualEndpoint) {
            $0.manualConnection?.validationError = "Enter a valid Wireless debugging port (1–65535), not the pairing port."
        }
    }

    @Test
    func forgettingCurrentDeviceDisconnectsAndClearsEveryEntryPoint() async {
        let paired = PairedDevice(
            name: "Pixel",
            publicKey: Data([1]),
            lastHost: "192.168.1.20",
            serviceName: "adb-pixel"
        )
        let discovered = DiscoveredDevice(
            id: "adb-pixel",
            name: "Pixel",
            host: "192.168.1.20",
            port: 37777,
            isPaired: true
        )
        let disconnected = LockIsolated(false)
        let savedDevices = LockIsolated<[PairedDevice]>([paired])
        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [discovered],
                pairedDevices: [paired],
                connectionState: .connected,
                lastConnectionDevice: discovered,
                pendingForgetDeviceID: paired.id
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
            $0.adbClient.disconnect = { disconnected.setValue(true) }
        }

        await store.send(.confirmForgetPairedDevice) {
            $0.discoveredDevices[0].isPaired = false
            $0.pairedDevices = []
            $0.lastConnectionDevice = nil
            $0.pendingForgetDeviceID = nil
        }
        await store.receive(\.disconnect) {
            $0.connectionState = .disconnected
            $0.lastConnectionError = nil
        }

        #expect(savedDevices.value.isEmpty)
        #expect(disconnected.value)
    }

    @Test
    func resettingADBIdentityClearsKeychainAndEverySavedEntryPoint() async {
        let paired = PairedDevice(
            name: "Pixel",
            guid: "pixel-guid",
            lastHost: "192.168.1.20",
            serviceName: "adb-pixel"
        )
        let discovered = DiscoveredDevice(
            id: "adb-pixel",
            name: "Pixel",
            host: "192.168.1.20",
            port: 37777,
            isPaired: true
        )
        let didResetIdentity = LockIsolated(false)
        let savedDevices = LockIsolated<[PairedDevice]>([paired])
        let store = TestStore(
            initialState: ConnectionFeature.State(
                discoveredDevices: [discovered],
                pairedDevices: [paired],
                connectionState: .connected,
                lastConnectionDevice: discovered,
                lastConnectionError: "old error",
                manualConnection: ConnectionFeature.ManualConnection(
                    pairedDeviceID: paired.id,
                    deviceName: "Pixel",
                    hostInput: "192.168.1.20",
                    portInput: "37777"
                ),
                pendingForgetDeviceID: paired.id,
                pairing: PairingFeature.State()
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = {}
            $0.adbClient.resetIdentity = { didResetIdentity.setValue(true) }
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
            $0.deviceDiscoveryClient.start = { _ in
                AsyncStream { continuation in
                    continuation.yield(.devices([]))
                    continuation.finish()
                }
            }
        }

        await store.send(.requestResetADBIdentity) {
            $0.isResetIdentityConfirmationPresented = true
        }
        await store.send(.confirmResetADBIdentity) {
            $0.isResetIdentityConfirmationPresented = false
        }
        await store.receive(\.disconnect) {
            $0.connectionState = .disconnected
            $0.lastConnectionError = nil
        }
        await store.receive(\.resetADBIdentitySucceeded) {
            $0.discoveredDevices[0].isPaired = false
            $0.pairedDevices = []
            $0.lastConnectionDevice = nil
            $0.lastConnectionError = nil
            $0.manualConnection = nil
            $0.pendingForgetDeviceID = nil
            $0.pairing = nil
        }
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated) {
            $0.discoveredDevices = []
            $0.isScanning = false
        }

        #expect(didResetIdentity.value)
        #expect(savedDevices.value.isEmpty)
    }

    @Test
    func resettingADBIdentityFailureKeepsSavedDevicesAndShowsRecovery() async {
        let paired = PairedDevice(
            name: "Pixel",
            guid: "pixel-guid",
            lastHost: "192.168.1.20"
        )
        let savedDevices = LockIsolated<[PairedDevice]>([paired])
        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [paired])
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = {}
            $0.adbClient.resetIdentity = {
                throw ADBError.cryptoError("Keychain denied deletion")
            }
            $0.pairedDevicesClient.save = { savedDevices.setValue($0) }
        }

        await store.send(.requestResetADBIdentity) {
            $0.isResetIdentityConfirmationPresented = true
        }
        await store.send(.confirmResetADBIdentity) {
            $0.isResetIdentityConfirmationPresented = false
        }
        await store.receive(\.disconnect)
        await store.receive(\.resetADBIdentityFailed) {
            $0.lastConnectionError =
                "The ADB identity could not be removed. Unlock this iPhone or iPad and try again. "
                + "Crypto error: Keychain denied deletion"
        }

        #expect(store.state.pairedDevices == [paired])
        #expect(savedDevices.value == [paired])
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
        let savedSettings = LockIsolated<DebugSettings?>(nil)

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
            $0.debugSettingsClient.save = { savedSettings.setValue($0) }
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

        #expect(savedSettings.value == expectedSettings)
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
        let savedSettings = LockIsolated<DebugSettings?>(nil)

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
            $0.debugSettingsClient.save = { savedSettings.setValue($0) }
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

        #expect(savedSettings.value == expectedSettings)
    }

    @Test
    func debugSettingsCanBeSeededFromLaunchEnvironment() {
        let settings = DebugSettings.resolved(
            stored: .defaultValue,
            arguments: ["iADB", "--iadb-debug-android-emulator"],
            environment: [
                "IADB_DEBUG_ANDROID_HOST": "10.0.2.2",
                "IADB_DEBUG_ANDROID_PORT": "٥٥٥٦"
            ]
        )

        #expect(settings.useAndroidEmulator)
        #expect(settings.emulatorHost == "10.0.2.2")
        #expect(settings.emulatorPortInput == "5556")
    }
    #endif
}
