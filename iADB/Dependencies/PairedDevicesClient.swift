import Foundation
import ComposableArchitecture

struct PairedDevicesClient: Sendable {
    var load: @Sendable () -> [PairedDevice]
    var save: @Sendable ([PairedDevice]) -> Void
}

extension PairedDevicesClient: DependencyKey {
    private static let key = "pairedDevices"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
                    return []
                }
                return devices
            },
            save: { devices in
                guard let data = try? JSONEncoder().encode(devices) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        )
    }

    static var previewValue: Self {
        Self(
            load: { [PairedDevice(name: "Preview", publicKey: Data(), lastHost: "10.0.0.1")] },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("PairedDevicesClient.load"),
            save: unimplemented("PairedDevicesClient.save")
        )
    }
}

extension DependencyValues {
    var pairedDevicesClient: PairedDevicesClient {
        get { self[PairedDevicesClient.self] }
        set { self[PairedDevicesClient.self] = newValue }
    }
}
