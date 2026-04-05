import ComposableArchitecture
import Testing
@testable import iADB

@MainActor
struct PairingFeatureTests {
    @Test
    func pairWithCodeSuccess() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "37000",
                pairingCode: "123456"
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.adbPairing.pair = { _, _, _ in
                ADBPairing.PeerInfo(name: "Pixel 7", guid: "", publicKey: Data())
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
        }
        await store.receive(\.pairingResult.success) {
            $0.pairingState = .success("Paired with Pixel 7")
        }
    }

    @Test
    func pairWithCodeError() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "37000",
                pairingCode: "999999"
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.adbPairing.pair = { _, _, _ in
                throw ADBPairing.PairingError.pairingRejected
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
        }
        await store.receive(\.pairingResult.failure) {
            $0.pairingState = .error("Pairing was rejected by the device")
        }
    }

    @Test
    func pairWithCodeEmptyHost() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "",
                portInput: "37000",
                pairingCode: "123456"
            )
        ) {
            PairingFeature()
        }

        await store.send(.pairWithCode)
        // No effect — empty host
    }

    @Test
    func pairWithCodeEmptyCode() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "37000",
                pairingCode: ""
            )
        ) {
            PairingFeature()
        }

        await store.send(.pairWithCode)
        // No effect — empty code
    }

    @Test
    func pairWithCodeInvalidPort() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "abc",
                pairingCode: "123456"
            )
        ) {
            PairingFeature()
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .error("Invalid port number")
        }
    }

    @Test
    func reset() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                pairingCode: "123456",
                pairingState: .success("OK")
            )
        ) {
            PairingFeature()
        }

        await store.send(.reset) {
            $0.pairingCode = ""
            $0.pairingState = .idle
        }
    }
}
