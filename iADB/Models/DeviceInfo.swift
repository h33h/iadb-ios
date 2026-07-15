import Foundation

/// Detailed device info fetched via ADB
struct DeviceDetails: Equatable {
    var model: String = ""
    var manufacturer: String = ""
    var androidVersion: String = ""
    var sdkVersion: String = ""
    var serialNumber: String = ""
    var buildFingerprint: String = ""
    var batteryLevel: String = ""
    var batteryStatus: String = ""
    var screenResolution: String = ""
    var ipAddress: String = ""
    var totalMemory: String = ""
    var availableMemory: String = ""
    var totalStorage: String = ""
    var availableStorage: String = ""
    var cpuAbi: String = ""
    var deviceName: String = ""

    var displayTitle: String {
        if !model.isEmpty { return model }
        return String(localized: "Android Device")
    }

    var localizedBatteryStatus: String {
        switch batteryStatus {
        case "Charging": String(localized: "Charging")
        case "Discharging": String(localized: "Discharging")
        case "Not charging": String(localized: "Not charging")
        case "Full": String(localized: "Full")
        case "Unknown": String(localized: "Unknown")
        default: batteryStatus
        }
    }

    var snapshotText: String {
        let sections: [(String, [(String, String)])] = [
            (String(localized: "Identity"), [
                (String(localized: "Model"), model),
                (String(localized: "Manufacturer"), manufacturer),
                (String(localized: "Device Name"), deviceName),
                (String(localized: "Serial Number"), serialNumber),
            ]),
            (String(localized: "System"), [
                (String(localized: "Android Version"), androidVersion),
                (String(localized: "SDK Level"), sdkVersion),
                (String(localized: "CPU ABI"), cpuAbi),
                (String(localized: "Build"), buildFingerprint),
            ]),
            (String(localized: "Hardware"), [
                (String(localized: "Battery Level"), batteryLevel),
                (String(localized: "Battery Status"), localizedBatteryStatus),
                (String(localized: "Screen"), screenResolution),
                (String(localized: "RAM Total"), totalMemory),
                (String(localized: "RAM Available"), availableMemory),
                (String(localized: "Storage Total"), totalStorage),
                (String(localized: "Storage Available"), availableStorage),
            ]),
            (String(localized: "Network"), [
                (String(localized: "IP Address"), ipAddress),
            ]),
        ]

        return sections
            .map { title, rows in
                let visibleRows = rows.filter { !$0.1.isEmpty }
                guard !visibleRows.isEmpty else { return nil }
                let body = visibleRows
                    .map { "\($0): \($1)" }
                    .joined(separator: "\n")
                return "## \(title)\n\(body)"
            }
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var isPaired: Bool
    /// Порт pairing-сервиса (появляется когда на Android нажали "Pair with code")
    var pairingPort: UInt16?
}

struct PairedDevice: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var guid: String
    var lastHost: String
    /// Persistent mDNS service name ("adb-R8YL10CLZCY-lKlRMT") — стабильный hash
    /// device cert. Матчим именно по нему, потому что host/port меняются при
    /// toggle wireless debug.
    var serviceName: String?

    init(id: UUID = UUID(), name: String, guid: String, lastHost: String, serviceName: String? = nil) {
        self.id = id
        self.name = name
        self.guid = guid
        self.lastHost = lastHost
        self.serviceName = serviceName
    }

    /// Source compatibility for data created before the pairing field was
    /// correctly identified as Android's device GUID.
    init(name: String, publicKey: Data, lastHost: String, serviceName: String? = nil) {
        self.init(
            name: name,
            guid: String(data: publicKey, encoding: .utf8) ?? publicKey.base64EncodedString(),
            lastHost: lastHost,
            serviceName: serviceName
        )
    }

    var publicKey: Data { Data(guid.utf8) }

    private enum CodingKeys: String, CodingKey {
        case id, name, guid, publicKey, lastHost, serviceName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastHost = try container.decode(String.self, forKey: .lastHost)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        if let storedGUID = try container.decodeIfPresent(String.self, forKey: .guid) {
            guid = storedGUID
        } else {
            let legacy = try container.decodeIfPresent(Data.self, forKey: .publicKey) ?? Data()
            guid = String(data: legacy, encoding: .utf8) ?? legacy.base64EncodedString()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(guid, forKey: .guid)
        try container.encode(lastHost, forKey: .lastHost)
        try container.encodeIfPresent(serviceName, forKey: .serviceName)
    }

    var displayName: String {
        name.isEmpty ? lastHost : name
    }
}

/// Connection state
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var statusText: String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting...")
        case .connected: return String(localized: "Connected")
        case .error(let msg): return String(localized: "Error: \(msg)")
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
