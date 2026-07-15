import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct PairingFeatureTests {
    @Test
    func pairWithCodeSuccess() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "٣٧٠٠٠",
                pairingCode: "١٢٣٤٥٦"
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.adbPairing.pair = { _, port, code in
                #expect(port == 37000)
                #expect(code == "123456")
                return ADBPairing.PeerInfo(name: "Pixel 7", guid: "pixel-guid")
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
            $0.phase = .negotiating
        }
        await store.receive(\.pairingCompleted) {
            $0.pairingState = .success("Paired with Pixel 7")
            $0.phase = .connecting
            $0.pairedDeviceName = "Pixel 7"
            $0.pairedDeviceGUID = "pixel-guid"
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
            $0.phase = .negotiating
        }
        await store.receive(\.pairingResult.failure) {
            $0.pairingState = .error("Pairing was rejected by the device")
            $0.phase = .idle
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
            $0.portValidationError = "Enter a Pairing port from 1 to 65535."
        }
    }

    @Test
    func pairWithCodeRejectsInvalidCodeBeforeStarting() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "37000",
                pairingCode: "12ab56"
            )
        ) {
            PairingFeature()
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .error("Invalid pairing code")
            $0.codeValidationError = "Enter the six-digit code shown on Android."
        }
    }

    @Test
    func pairWithCodeRejectsPortZero() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "0",
                pairingCode: "123456"
            )
        ) {
            PairingFeature()
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .error("Invalid port number")
            $0.portValidationError = "Enter a Pairing port from 1 to 65535."
        }
    }

    @Test
    func pairWithCodeTimeout() async {
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
                throw ADBPairing.PairingError.timeout
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
            $0.phase = .negotiating
        }
        await store.receive(\.pairingResult.failure) {
            $0.pairingState = .error("Pairing timed out")
            $0.phase = .idle
        }
    }

    @Test
    func pairWithCodeTLSFailed() async {
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
                throw ADBPairing.PairingError.tlsFailed("unknown certificate")
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
            $0.phase = .negotiating
        }
        await store.receive(\.pairingResult.failure) {
            $0.pairingState = .error("TLS handshake failed: unknown certificate")
            $0.phase = .idle
        }
    }

    @Test
    func pairWithCodeConnectionFailed() async {
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
                throw ADBPairing.PairingError.connectionFailed(
                    "Connection stuck (Network.NWError). Check that Local Network permission is granted and both devices are on the same WiFi."
                )
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
            $0.phase = .negotiating
        }
        await store.receive(\.pairingResult.failure) {
            $0.pairingState = .error("Pairing connection failed: Connection stuck (Network.NWError). Check that Local Network permission is granted and both devices are on the same WiFi.")
            $0.phase = .idle
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

    @Test
    func cancelPairingCancelsInFlightWork() async {
        let didCancel = LockIsolated(false)
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
                do {
                    try await Task.sleep(for: .seconds(60))
                    return ADBPairing.PeerInfo(name: "Android Device", guid: "guid")
                } catch {
                    didCancel.setValue(true)
                    throw error
                }
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
            $0.phase = .negotiating
        }
        await store.send(.cancelPairing) {
            $0.pairingState = .idle
            $0.phase = .idle
        }
        await Task.yield()
        #expect(didCancel.value)
    }
}
