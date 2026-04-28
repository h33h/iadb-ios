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
}
