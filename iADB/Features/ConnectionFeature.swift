import Foundation
import ComposableArchitecture
import os

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
        case removePairedDevice(serviceName: String)
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
                    // Матчим по serviceName (стабильный hash cert), а не по host.
                    // host меняется при toggle wireless debug, serviceName — нет.
                    if let match = paired.first(where: { $0.serviceName == devices[i].id })
                        ?? paired.first(where: { $0.lastHost == devices[i].host }) // fallback для старых записей без serviceName
                    {
                        devices[i].isPaired = true
                        devices[i].name = match.name
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
                guard let pairingPort = device.pairingPort else {
                    // Без активного pairing-сервиса pair невозможен — нужно
                    // нажать "Pair device with pairing code" на Android.
                    return .none
                }
                state.pairing = PairingFeature.State(
                    hostInput: device.host,
                    portInput: String(pairingPort),
                    isPrefilled: true,
                    serviceName: device.id
                )
                return .none

            case .removePairedDevice(let serviceName):
                state.pairedDevices.removeAll { $0.serviceName == serviceName }
                for i in state.discoveredDevices.indices where state.discoveredDevices[i].id == serviceName {
                    state.discoveredDevices[i].isPaired = false
                }
                return .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }

            case .pairing(.presented(.pairingCompleted(let name, let publicKey))):
                guard let pairingState = state.pairing else { return .none }
                let host = pairingState.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }

                let serviceName = pairingState.serviceName
                if let svc = serviceName {
                    state.pairedDevices.removeAll { $0.serviceName == svc }
                } else {
                    state.pairedDevices.removeAll { $0.publicKey == publicKey }
                }
                let paired = PairedDevice(name: name, publicKey: publicKey, lastHost: host, serviceName: serviceName)
                state.pairedDevices.append(paired)

                if let svc = serviceName,
                   let idx = state.discoveredDevices.firstIndex(where: { $0.id == svc }) {
                    state.discoveredDevices[idx].isPaired = true
                    state.discoveredDevices[idx].name = name
                }

                // Auto-connect after pairing — ищем по serviceName, host мог уже измениться
                let connectDevice = serviceName.flatMap { svc in
                    state.discoveredDevices.first(where: { $0.id == svc })
                } ?? state.discoveredDevices.first(where: { $0.host == host })

                let log = Logger(subsystem: "com.iadb.app", category: "adb")
                if let d = connectDevice {
                    let endpoint = "\(d.host):\(d.port)"
                    log.info("AUTO-CONNECT pairedHost=\(host, privacy: .public) → discovered=\(endpoint, privacy: .public)")
                } else {
                    let allHosts = state.discoveredDevices.map { "\($0.host):\($0.port)" }.joined(separator: ",")
                    log.error("AUTO-CONNECT no discovered device for pairedHost=\(host, privacy: .public). Discovered: \(allHosts, privacy: .public)")
                }
                state.pairing = nil // dismiss pairing sheet

                let saveEffect: Effect<ConnectionFeature.Action> = .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }
                if let device = connectDevice {
                    // Задержка нужна, чтобы adbd успел зарегистрировать новый ключ
                    // в trusted-list перед нашим TLS-подключением (race на commit).
                    let delayedConnect: Effect<ConnectionFeature.Action> = .run { send in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await send(.connectToDevice(device))
                    }
                    return .merge(saveEffect, delayedConnect)
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
