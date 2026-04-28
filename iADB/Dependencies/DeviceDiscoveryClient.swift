import Foundation
import ComposableArchitecture

struct DeviceDiscoveryClient: Sendable {
    var start: @Sendable ([Data]) -> AsyncStream<[DiscoveredDevice]>
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

    static var previewValue: Self {
        Self(
            start: { _ in
                AsyncStream { continuation in
                    continuation.yield([
                        DiscoveredDevice(id: "preview-1", name: "Pixel 7", host: "192.168.1.42", port: 38745, isPaired: true),
                        DiscoveredDevice(id: "preview-2", name: "Galaxy S24", host: "192.168.1.55", port: 42100, isPaired: false)
                    ])
                }
            },
            stop: {}
        )
    }

    static var testValue: Self {
        Self(
            start: unimplemented("DeviceDiscoveryClient.start"),
            stop: unimplemented("DeviceDiscoveryClient.stop")
        )
    }
}

extension DependencyValues {
    var deviceDiscoveryClient: DeviceDiscoveryClient {
        get { self[DeviceDiscoveryClient.self] }
        set { self[DeviceDiscoveryClient.self] = newValue }
    }
}
