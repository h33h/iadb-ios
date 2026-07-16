import ComposableArchitecture
import Foundation

@Reducer
struct ConnectionFeature {
    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var connectionState: ConnectionState = .disconnected
        var connectedDevice: DiscoveredDevice?
        var errorMessage: String?

    }

    enum Action {
        case loadSavedDevices
        case savedDevicesLoaded(Result<[PairedDevice], Error>)
        case startDiscovery
        case discoveryEvent(DeviceDiscoveryEvent)
        case stopDiscovery
        case connect(DiscoveredDevice)
        case connectionFinished(DiscoveredDevice, Result<String, Error>)
        case disconnect
        case savePairedDevice(PairedDevice)
        case pairedDeviceSaved(Result<[PairedDevice], Error>)
        case forgetDevice(UUID)
        case deviceForgotten(Result<[PairedDevice], Error>)
        case resetIdentity
        case identityReset(Result<Void, Error>)
    }

    private enum CancelID { case discovery, connection }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.deviceDiscoveryClient) var discoveryClient
    @Dependency(\.pairedDevicesClient) var pairedDevicesClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadSavedDevices:
                return .run { send in
                    await send(.savedDevicesLoaded(Result { try pairedDevicesClient.load() }))
                }

            case .savedDevicesLoaded(.success(let devices)):
                state.pairedDevices = devices
                state.errorMessage = nil
                return .none

            case .savedDevicesLoaded(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .startDiscovery:
                state.isScanning = true
                state.errorMessage = nil
                let keys = state.pairedDevices.map(\.publicKey)
                return .run { send in
                    for await event in discoveryClient.start(keys) {
                        await send(.discoveryEvent(event))
                    }
                }
                .cancellable(id: CancelID.discovery, cancelInFlight: true)

            case .discoveryEvent(.ready):
                state.isScanning = false
                return .none

            case .discoveryEvent(.devices(let devices)):
                state.discoveredDevices = devices
                return .none

            case .discoveryEvent(.failure(let message)):
                state.isScanning = false
                state.errorMessage = message
                return .none

            case .stopDiscovery:
                state.isScanning = false
                discoveryClient.stop()
                return .cancel(id: CancelID.discovery)

            case .connect(let device):
                state.connectionState = .connecting
                state.errorMessage = nil
                return .run { send in
                    do {
                        let banner = try await adbClient.connect(device.host, device.port)
                        await send(.connectionFinished(device, .success(banner)))
                    } catch {
                        await send(.connectionFinished(device, .failure(error)))
                    }
                }
                .cancellable(id: CancelID.connection, cancelInFlight: true)

            case .connectionFinished(let device, .success):
                state.connectedDevice = device
                state.connectionState = .connected
                return .none

            case .connectionFinished(_, .failure(let error)):
                state.connectedDevice = nil
                state.connectionState = .error(error.localizedDescription)
                state.errorMessage = error.localizedDescription
                return .none

            case .disconnect:
                adbClient.disconnect()
                state.connectedDevice = nil
                state.connectionState = .disconnected
                return .cancel(id: CancelID.connection)

            case .savePairedDevice(let device):
                var devices = state.pairedDevices.filter { $0.id != device.id }
                devices.append(device)
                let savedDevices = devices
                return .run { send in
                    await send(.pairedDeviceSaved(Result {
                        try pairedDevicesClient.save(savedDevices)
                        return savedDevices
                    }))
                }

            case .pairedDeviceSaved(.success(let devices)),
                 .deviceForgotten(.success(let devices)):
                state.pairedDevices = devices
                state.errorMessage = nil
                return .none

            case .pairedDeviceSaved(.failure(let error)),
                 .deviceForgotten(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .forgetDevice(let id):
                let devices = state.pairedDevices.filter { $0.id != id }
                return .run { send in
                    await send(.deviceForgotten(Result {
                        try pairedDevicesClient.save(devices)
                        return devices
                    }))
                }

            case .resetIdentity:
                return .run { send in
                    do {
                        try await adbClient.resetIdentity()
                        try pairedDevicesClient.reset()
                        try adbClient.completeIdentityReset()
                        await send(.identityReset(.success(())))
                    } catch {
                        await send(.identityReset(.failure(error)))
                    }
                }

            case .identityReset(.success):
                state = State()
                return .none

            case .identityReset(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}
