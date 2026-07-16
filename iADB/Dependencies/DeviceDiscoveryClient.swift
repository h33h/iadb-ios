import Foundation
import ComposableArchitecture

enum DeviceDiscoveryEvent: Equatable {
    /// Both Bonjour browsers are running. The initial scan is complete even if
    /// no services have been published yet.
    case ready
    case devices([DiscoveredDevice])
    case failure(String)
}

struct DeviceDiscoveryClient: Sendable {
    var start: @Sendable ([Data]) -> AsyncStream<DeviceDiscoveryEvent>
    var stop: @Sendable () -> Void
}

extension DeviceDiscoveryClient: DependencyKey {
    static var liveValue: Self {
        let discovery = ADBDeviceDiscovery()
        return Self(
            start: { pairedKeys in discovery.start(pairedKeys: pairedKeys) },
            stop: { discovery.stop() }
        )
    }

    static var testValue: Self {
        Self(
            start: { _ in AsyncStream { $0.finish() } },
            stop: {}
        )
    }
}

extension DependencyValues {
    var deviceDiscoveryClient: DeviceDiscoveryClient {
        get { self[DeviceDiscoveryClient.self] }
        set { self[DeviceDiscoveryClient.self] = newValue }
    }
}
