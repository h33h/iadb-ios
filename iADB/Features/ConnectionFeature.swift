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

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.savedDevicesClient) var savedDevicesClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                state.savedDevices = savedDevicesClient.load()
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

            case .connectToDevice(let device):
                return .send(.connect(host: device.host, port: device.port))

            case .quickConnect:
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }
                let port = UInt16(state.portInput) ?? 5555
                return .send(.connect(host: host, port: port))

            case .disconnect:
                adbClient.disconnect()
                state.connectionState = .disconnected
                return .none

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
                let device = SavedDevice(name: name, host: host, port: port)
                state.savedDevices.append(device)
                savedDevicesClient.save(state.savedDevices)
                state.hostInput = ""
                state.portInput = "5555"
                state.deviceNameInput = ""
                state.showingAddDevice = false
                return .none

            case .removeDevice(let device):
                state.savedDevices.removeAll { $0.id == device.id }
                savedDevicesClient.save(state.savedDevices)
                return .none

            case .removeDevices(let offsets):
                state.savedDevices.remove(atOffsets: offsets)
                savedDevicesClient.save(state.savedDevices)
                return .none

            case .toggleAddDevice:
                state.showingAddDevice.toggle()
                return .none

            case .showPairing:
                state.pairing = PairingFeature.State()
                return .none

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
