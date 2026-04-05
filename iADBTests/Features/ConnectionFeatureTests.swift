import ComposableArchitecture
import Testing
@testable import iADB

@MainActor
struct ConnectionFeatureTests {
    @Test
    func onAppearLoadsSavedDevices() async {
        let devices = [SavedDevice(name: "Test", host: "192.168.1.100", port: 5555)]
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.savedDevicesClient.load = { devices }
        }

        await store.send(.onAppear) {
            $0.savedDevices = devices
        }
    }

    @Test
    func quickConnectSuccess() async {
        let store = TestStore(
            initialState: ConnectionFeature.State(hostInput: "192.168.1.100", portInput: "5555")
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in "device::Pixel" }
        }

        await store.send(.quickConnect)
        await store.receive(\.connect) {
            $0.connectionState = .connecting
        }
        await store.receive(\.connectionResult.success) {
            $0.connectionState = .connected
        }
    }

    @Test
    func quickConnectEmptyHost() async {
        let store = TestStore(
            initialState: ConnectionFeature.State(hostInput: "", portInput: "5555")
        ) {
            ConnectionFeature()
        }

        await store.send(.quickConnect)
        // No effect — empty host
    }

    @Test
    func quickConnectError() async {
        let store = TestStore(
            initialState: ConnectionFeature.State(hostInput: "192.168.1.100", portInput: "5555")
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in throw ADBError.connectionFailed("timeout") }
        }

        await store.send(.quickConnect)
        await store.receive(\.connect) {
            $0.connectionState = .connecting
        }
        await store.receive(\.connectionResult.failure) {
            $0.connectionState = .error("Connection failed: timeout")
        }
    }

    @Test
    func connectToSavedDevice() async {
        let device = SavedDevice(name: "Test", host: "10.0.0.1", port: 5555)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in "device::banner" }
        }

        await store.send(.connectToDevice(device))
        await store.receive(\.connect) {
            $0.connectionState = .connecting
        }
        await store.receive(\.connectionResult.success) {
            $0.connectionState = .connected
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
    func addDevice() async {
        var savedDevices: [SavedDevice]?
        let store = TestStore(
            initialState: ConnectionFeature.State(
                hostInput: "192.168.1.50",
                portInput: "5555",
                deviceNameInput: "My Phone"
            )
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.savedDevicesClient.save = { devices in savedDevices = devices }
        }

        store.exhaustivity = .off
        await store.send(.addDevice)
        store.exhaustivity = .on

        #expect(store.state.savedDevices.count == 1)
        #expect(store.state.savedDevices[0].host == "192.168.1.50")
        #expect(store.state.savedDevices[0].name == "My Phone")
        #expect(store.state.hostInput == "")
        #expect(store.state.portInput == "5555")
        #expect(store.state.showingAddDevice == false)
        #expect(savedDevices?.count == 1)
    }

    @Test
    func removeDevice() async {
        let device = SavedDevice(name: "Test", host: "1.2.3.4", port: 5555)
        var savedDevices: [SavedDevice]?
        let store = TestStore(
            initialState: ConnectionFeature.State(savedDevices: [device])
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.savedDevicesClient.save = { devices in savedDevices = devices }
        }

        await store.send(.removeDevice(device)) {
            $0.savedDevices = []
        }
        #expect(savedDevices?.isEmpty == true)
    }

    @Test
    func showPairing() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showPairing) {
            $0.pairing = PairingFeature.State()
        }
    }

    @Test
    func toggleAddDevice() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.toggleAddDevice) {
            $0.showingAddDevice = true
        }
    }

    @Test
    func duplicateConnectIgnored() async {
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connecting)
        ) {
            ConnectionFeature()
        }

        await store.send(.connect(host: "1.2.3.4", port: 5555))
        // No state change — already connecting
    }
}
