import Foundation
import ComposableArchitecture

@Reducer
struct ConnectionFeature {
    @ObservableState
    struct State: Equatable {
        var savedDevices: [SavedDevice] = []
        var connectionState: ConnectionState = .disconnected
        var hostInput = ""
        var portInput = "5555"
        var deviceNameInput = ""
        var showingAddDevice = false
        @Presents var pairing: PairingFeature.State?
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case devicesLoaded([SavedDevice])
        case connect(host: String, port: UInt16)
        case connectToDevice(SavedDevice)
        case quickConnect
        case disconnect
        case connectionResult(Result<String, Error>)
        case addDevice
        case removeDevice(SavedDevice)
        case removeDevices(IndexSet)
        case toggleAddDevice
        case showPairing
        case pairing(PresentationAction<PairingFeature.Action>)
    }

    private enum CancelID { case connection }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.savedDevicesClient) var savedDevicesClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                return .run { send in
                    let devices = savedDevicesClient.load()
                    await send(.devicesLoaded(devices))
                }

            case .devicesLoaded(let devices):
                state.savedDevices = devices
                return .none

            case .connect(let host, let port):
                guard state.connectionState != .connecting else { return .none }
                state.connectionState = .connecting

                return .run { send in
                    let banner = try await adbClient.connect(host, port)
                    await send(.connectionResult(.success(banner)))
                } catch: { error, send in
                    await send(.connectionResult(.failure(error)))
                }
                .cancellable(id: CancelID.connection)

            case .connectToDevice(let device):
                return .send(.connect(host: device.host, port: device.port))

            case .quickConnect:
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }
                guard let port = UInt16(state.portInput) else {
                    state.connectionState = .error("Invalid port number")
                    return .none
                }
                return .send(.connect(host: host, port: port))

            case .disconnect:
                state.connectionState = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in
                        adbClient.disconnect()
                    }
                )

            case .connectionResult(.success):
                state.connectionState = .connected
                return .none

            case .connectionResult(.failure(let error)):
                state.connectionState = .error(error.localizedDescription)
                return .none

            case .addDevice:
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }
                let port = UInt16(state.portInput) ?? 5555
                let name = state.deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !state.savedDevices.contains(where: { $0.host == host && $0.port == port }) else {
                    return .none
                }
                let device = SavedDevice(name: name, host: host, port: port)
                state.savedDevices.append(device)
                state.hostInput = ""
                state.portInput = "5555"
                state.deviceNameInput = ""
                state.showingAddDevice = false
                return .run { [devices = state.savedDevices] _ in
                    savedDevicesClient.save(devices)
                }

            case .removeDevice(let device):
                state.savedDevices.removeAll { $0.id == device.id }
                return .run { [devices = state.savedDevices] _ in
                    savedDevicesClient.save(devices)
                }

            case .removeDevices(let offsets):
                state.savedDevices.remove(atOffsets: offsets)
                return .run { [devices = state.savedDevices] _ in
                    savedDevicesClient.save(devices)
                }

            case .toggleAddDevice:
                state.showingAddDevice.toggle()
                return .none

            case .showPairing:
                state.pairing = PairingFeature.State()
                return .none

            case .pairing(.presented(.pairingResult(.success))):
                guard let pairing = state.pairing else { return .none }
                let host = pairing.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let portStr = pairing.connectionPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let port = UInt16(portStr) ?? 5555
                let name = pairing.pairedDeviceName ?? ""
                guard !host.isEmpty,
                      !state.savedDevices.contains(where: { $0.host == host && $0.port == port }) else {
                    return .none
                }
                let device = SavedDevice(name: name, host: host, port: port)
                state.savedDevices.append(device)
                return .run { [devices = state.savedDevices] _ in
                    savedDevicesClient.save(devices)
                }

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
