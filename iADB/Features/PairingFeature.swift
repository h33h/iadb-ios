import ComposableArchitecture
import Foundation

@Reducer
struct PairingFeature {
    @ObservableState
    struct State: Equatable {
        var host = ""
        var port = ""
        var code = ""
        var isPairing = false
        var pairedDeviceName: String?
        var pairedDeviceGUID: String?
        var errorMessage: String?
    }

    enum Action {
        case setHost(String)
        case setPort(String)
        case setCode(String)
        case pair
        case completed(name: String, guid: String)
        case failed(Error)
        case cancel
    }

    private enum CancelID { case pairing }
    @Dependency(\.adbPairing) var adbPairing

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setHost(let host):
                state.host = host
                state.errorMessage = nil
                return .none

            case .setPort(let port):
                state.port = String(port.filter(\.isNumber).prefix(5))
                state.errorMessage = nil
                return .none

            case .setCode(let code):
                state.code = String(code.filter(\.isNumber).prefix(6))
                state.errorMessage = nil
                return .none

            case .pair:
                let host = state.host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty,
                      let port = UInt16(state.port),
                      let code = try? ADBPairing.normalizedPairingCode(state.code) else {
                    state.errorMessage = "Invalid pairing address or code"
                    return .none
                }
                state.isPairing = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let peer = try await adbPairing.pair(host, port, code)
                        await send(.completed(name: peer.name, guid: peer.guid))
                    } catch is CancellationError {
                    } catch {
                        await send(.failed(error))
                    }
                }
                .cancellable(id: CancelID.pairing, cancelInFlight: true)

            case .completed(let name, let guid):
                state.isPairing = false
                state.pairedDeviceName = name
                state.pairedDeviceGUID = guid
                return .none

            case .failed(let error):
                state.isPairing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isPairing = false
                return .cancel(id: CancelID.pairing)
            }
        }
    }
}
