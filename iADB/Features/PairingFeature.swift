import Foundation
import ComposableArchitecture

@Reducer
struct PairingFeature {
    @ObservableState
    struct State: Equatable {
        var hostInput = ""
        var portInput = ""
        var pairingCode = ""
        var pairingState: PairingState = .idle
        var pairedDeviceName: String?
        var pairedDeviceGUID: String?
        var isPrefilled = false
        /// mDNS service name спариваемого устройства (если pair вызван из discovery).
        var serviceName: String?
    }

    enum PairingState: Equatable {
        case idle
        case pairing
        case success(String)
        case error(String)

        var isPairing: Bool {
            if case .pairing = self { return true }
            return false
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case pairWithCode
        case pairingResult(Result<String, Error>)
        case pairingCompleted(name: String, guid: String)
        case cancelPairing
        case reset
    }

    private enum CancelID { case pairing }

    @Dependency(\.adbPairing) var adbPairing

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .pairWithCode:
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = state.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !code.isEmpty else { return .none }
                guard let normalizedCode = try? ADBPairing.normalizedPairingCode(code) else {
                    state.pairingState = .error("Invalid pairing code")
                    return .none
                }
                guard let port = LocalizedDecimalInput.positiveUInt16(state.portInput) else {
                    state.pairingState = .error("Invalid port number")
                    return .none
                }

                state.pairingState = .pairing

                return .run { send in
                    let peerInfo = try await adbPairing.pair(host, port, normalizedCode)
                    await send(.pairingCompleted(name: peerInfo.name, guid: peerInfo.guid))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.pairingResult(.failure(error)))
                }
                .cancellable(id: CancelID.pairing)

            case .pairingCompleted(let name, let guid):
                state.pairingState = .success("Paired with \(name)")
                state.pairedDeviceName = name
                state.pairedDeviceGUID = guid
                return .none

            case .pairingResult(.success(let deviceName)):
                state.pairingState = .success("Paired with \(deviceName)")
                state.pairedDeviceName = deviceName
                return .none

            case .pairingResult(.failure(let error)):
                state.pairingState = .error(error.localizedDescription)
                return .none

            case .cancelPairing:
                guard state.pairingState.isPairing else { return .none }
                state.pairingState = .idle
                return .cancel(id: CancelID.pairing)

            case .reset:
                state.pairingCode = ""
                state.pairingState = .idle
                return .cancel(id: CancelID.pairing)
            }
        }
    }
}
