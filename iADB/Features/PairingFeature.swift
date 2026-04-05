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
                guard let port = UInt16(state.portInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    state.pairingState = .error("Invalid port number")
                    return .none
                }

                state.pairingState = .pairing

                return .run { send in
                    let peerInfo = try await adbPairing.pair(host, port, code)
                    await send(.pairingResult(.success("Paired with \(peerInfo.name)")))
                } catch: { error, send in
                    await send(.pairingResult(.failure(error)))
                }
                .cancellable(id: CancelID.pairing)

            case .pairingResult(.success(let message)):
                state.pairingState = .success(message)
                return .none

            case .pairingResult(.failure(let error)):
                state.pairingState = .error(error.localizedDescription)
                return .none

            case .reset:
                state.pairingCode = ""
                state.pairingState = .idle
                return .none
            }
        }
    }
}
