import Foundation
import ComposableArchitecture

/// TCA dependency for persisting saved devices via UserDefaults
struct SavedDevicesClient: Sendable {
    var load: @Sendable () -> [SavedDevice]
    var save: @Sendable ([SavedDevice]) -> Void
}

extension SavedDevicesClient: DependencyKey {
    private static let key = "savedDevices"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let devices = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
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
            load: { [SavedDevice(name: "Preview", host: "10.0.0.1", port: 5555)] },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("SavedDevicesClient.load"),
            save: unimplemented("SavedDevicesClient.save")
        )
    }
}

extension DependencyValues {
    var savedDevicesClient: SavedDevicesClient {
        get { self[SavedDevicesClient.self] }
        set { self[SavedDevicesClient.self] = newValue }
    }
}
