import Foundation
import ComposableArchitecture

/// TCA dependency wrapping ADBPairing for testable pairing operations
struct ADBPairingDependency: Sendable {
    var pair: @Sendable (_ host: String, _ port: UInt16, _ code: String) async throws -> ADBPairing.PeerInfo
}

extension ADBPairingDependency: DependencyKey {
    static var liveValue: Self {
        Self(
            pair: { host, port, code in
                try await ADBPairing.pair(host: host, port: port, code: code)
            }
        )
    }

    static var testValue: Self {
        Self(
            pair: unimplemented("ADBPairingDependency.pair")
        )
    }
}

extension DependencyValues {
    var adbPairing: ADBPairingDependency {
        get { self[ADBPairingDependency.self] }
        set { self[ADBPairingDependency.self] = newValue }
    }
}
