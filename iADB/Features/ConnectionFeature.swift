import Foundation
import ComposableArchitecture

@Reducer
struct ConnectionFeature {
    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var connectionState: ConnectionState = .disconnected
        @Presents var pairing: PairingFeature.State?
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case startDiscovery
        case devicesUpdated([DiscoveredDevice])
        case connectToDevice(DiscoveredDevice)
        case disconnect
        case connectionResult(Result<String, Error>)
        case showPairingForDevice(DiscoveredDevice)
        case showManualPairing
        case pairing(PresentationAction<PairingFeature.Action>)
    }

    private enum CancelID { case connection, discovery }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.pairedDevicesClient) var pairedDevicesClient
    @Dependency(\.deviceDiscoveryClient) var deviceDiscoveryClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                state.pairedDevices = pairedDevicesClient.load()
                return .send(.startDiscovery)

            case .startDiscovery:
                state.isScanning = true
                let pairedKeys = state.pairedDevices.map(\.publicKey)
                return .run { send in
                    let stream = deviceDiscoveryClient.start(pairedKeys)
                    for await devices in stream {
                        await send(.devicesUpdated(devices))
                    }
                }
                .cancellable(id: CancelID.discovery)

            case .devicesUpdated(var devices):
                let paired = state.pairedDevices
                for i in devices.indices {
                    if paired.contains(where: { $0.lastHost == devices[i].host }) {
                        devices[i].isPaired = true
                        if let match = paired.first(where: { $0.lastHost == devices[i].host }) {
                            devices[i].name = match.name
                        }
                    }
                }
                state.discoveredDevices = devices
                return .none

            case .connectToDevice(let device):
                guard state.connectionState != .connecting else { return .none }
                state.connectionState = .connecting

                return .run { [host = device.host, port = device.port] send in
                    let banner = try await adbClient.connect(host, port)
                    await send(.connectionResult(.success(banner)))
                } catch: { error, send in
                    await send(.connectionResult(.failure(error)))
                }
                .cancellable(id: CancelID.connection)

            case .disconnect:
                state.connectionState = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in adbClient.disconnect() }
                )

            case .connectionResult(.success):
                state.connectionState = .connected
                return .none

            case .connectionResult(.failure(let error)):
                state.connectionState = .error(error.localizedDescription)
                return .none

            case .showPairingForDevice(let device):
                if let pairingPort = device.pairingPort {
                    // Pairing-сервис найден — IP и порт заполнены, нужен только код
                    state.pairing = PairingFeature.State(
                        hostInput: device.host,
                        portInput: String(pairingPort),
                        isPrefilled: true
                    )
                } else {
                    // Pairing-сервис не найден — IP заполнен, порт вводится вручную
                    state.pairing = PairingFeature.State(
                        hostInput: device.host
                    )
                }
                return .none

            case .showManualPairing:
                state.pairing = PairingFeature.State()
                return .none

            case .pairing(.presented(.pairingCompleted(let name, let publicKey))):
                guard let pairingState = state.pairing else { return .none }
                let host = pairingState.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }
                guard !state.pairedDevices.contains(where: { $0.publicKey == publicKey }) else {
                    return .none
                }
                let paired = PairedDevice(name: name, publicKey: publicKey, lastHost: host)
                state.pairedDevices.append(paired)
                if let idx = state.discoveredDevices.firstIndex(where: { $0.host == host }) {
                    state.discoveredDevices[idx].isPaired = true
                    state.discoveredDevices[idx].name = name
                }

                // Auto-connect after pairing: find the device's connect port from mDNS discovery
                let connectDevice = state.discoveredDevices.first(where: { $0.host == host })
                state.pairing = nil // dismiss pairing sheet

                let saveEffect: Effect<ConnectionFeature.Action> = .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }
                if let device = connectDevice {
                    return .merge(saveEffect, .send(.connectToDevice(device)))
                }
                return saveEffect

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
