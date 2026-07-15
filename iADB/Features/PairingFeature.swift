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
        var phase: Phase = .idle
        var pairedDeviceName: String?
        var pairedDeviceGUID: String?
        var isPrefilled = false
        var hostValidationError: String?
        var portValidationError: String?
        var codeValidationError: String?
        /// mDNS service name спариваемого устройства (если pair вызван из discovery).
        var serviceName: String?

        var isBusy: Bool { phase == .validating || phase == .negotiating || phase == .connecting }
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

    enum Phase: Equatable {
        case idle
        case validating
        case negotiating
        case connecting
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
                state.pairingCode = String(state.pairingCode.filter(\.isNumber).prefix(6))
                state.hostValidationError = nil
                state.portValidationError = nil
                state.codeValidationError = nil
                return .none

            case .pairWithCode:
                state.phase = .validating
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = state.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !code.isEmpty else {
                    state.phase = .idle
                    return .none
                }
                guard let normalizedCode = try? ADBPairing.normalizedPairingCode(code) else {
                    state.pairingState = .error(String(localized: "Invalid pairing code"))
                    state.codeValidationError = String(localized: "Enter the six-digit code shown on Android.")
                    state.phase = .idle
                    return .none
                }
                guard let port = LocalizedDecimalInput.positiveUInt16(state.portInput) else {
                    state.pairingState = .error(String(localized: "Invalid port number"))
                    state.portValidationError = String(localized: "Enter a Pairing port from 1 to 65535.")
                    state.phase = .idle
                    return .none
                }

                state.pairingState = .pairing
                state.phase = .negotiating
                state.hostValidationError = nil
                state.portValidationError = nil
                state.codeValidationError = nil

                return .run { send in
                    let peerInfo = try await adbPairing.pair(host, port, normalizedCode)
                    await send(.pairingCompleted(name: peerInfo.name, guid: peerInfo.guid))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.pairingResult(.failure(error)))
                }
                .cancellable(id: CancelID.pairing)

            case .pairingCompleted(let name, let guid):
                state.pairingState = .success(String(localized: "Paired with \(name)"))
                state.phase = .connecting
                state.pairedDeviceName = name
                state.pairedDeviceGUID = guid
                return .none

            case .pairingResult(.success(let deviceName)):
                state.pairingState = .success(String(localized: "Paired with \(deviceName)"))
                state.phase = .connecting
                state.pairedDeviceName = deviceName
                return .none

            case .pairingResult(.failure(let error)):
                state.pairingState = .error(error.localizedDescription)
                state.phase = .idle
                return .none

            case .cancelPairing:
                guard state.pairingState.isPairing else { return .none }
                state.pairingState = .idle
                state.phase = .idle
                return .cancel(id: CancelID.pairing)

            case .reset:
                state.pairingCode = ""
                state.pairingState = .idle
                state.phase = .idle
                state.hostValidationError = nil
                state.portValidationError = nil
                state.codeValidationError = nil
                return .cancel(id: CancelID.pairing)
            }
        }
    }
}
