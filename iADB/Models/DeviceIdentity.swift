import Foundation

struct DeviceIdentity: Equatable, Codable, Hashable, Sendable {
    static let unknownID = "unknown"

    var stableID: String
    var displayName: String
    var adbFingerprint: String?

    static func resolved(
        from device: DiscoveredDevice,
        pairedDevices: [PairedDevice]
    ) -> Self {
        let paired = pairedDevices.first {
            (!$0.guid.isEmpty && $0.guid == device.id) ||
            ($0.serviceName != nil && $0.serviceName == device.id) ||
            ($0.lastHost == device.host && ($0.lastPort == nil || $0.lastPort == device.port))
        }
        if let guid = paired?.guid, !guid.isEmpty {
            return Self(
                stableID: "guid:\(guid)",
                displayName: paired?.displayName ?? device.name,
                adbFingerprint: guid
            )
        }
        if let serviceName = paired?.serviceName ?? (device.id.isEmpty ? nil : device.id) {
            return Self(
                stableID: "service:\(serviceName)",
                displayName: paired?.displayName ?? device.name,
                adbFingerprint: nil
            )
        }
        // Manual endpoints receive a generated record ID before reaching this
        // path. Host and port are deliberately never used as identity.
        return Self(
            stableID: "manual:\(device.id)",
            displayName: device.name,
            adbFingerprint: nil
        )
    }

    static func resolved(from device: PairedDevice) -> Self {
        if !device.guid.isEmpty {
            return Self(
                stableID: "guid:\(device.guid)",
                displayName: device.displayName,
                adbFingerprint: device.guid
            )
        }
        if let serviceName = device.serviceName, !serviceName.isEmpty {
            return Self(
                stableID: "service:\(serviceName)",
                displayName: device.displayName,
                adbFingerprint: nil
            )
        }
        return Self(
            stableID: "service:saved-\(device.id.uuidString)",
            displayName: device.displayName,
            adbFingerprint: nil
        )
    }
}
