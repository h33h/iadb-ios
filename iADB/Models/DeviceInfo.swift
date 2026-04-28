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
    var cpuAbi: String = ""
    var deviceName: String = ""

    var displayTitle: String {
        if !model.isEmpty { return model }
        return "Android Device"
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
    var publicKey: Data
    var lastHost: String
    /// Persistent mDNS service name ("adb-R8YL10CLZCY-lKlRMT") — стабильный hash
    /// device cert. Матчим именно по нему, потому что host/port меняются при
    /// toggle wireless debug.
    var serviceName: String?

    init(name: String, publicKey: Data, lastHost: String, serviceName: String? = nil) {
        self.id = UUID()
        self.name = name
        self.publicKey = publicKey
        self.lastHost = lastHost
        self.serviceName = serviceName
    }

    var displayName: String {
        name.isEmpty ? lastHost : name
    }
}

/// Connection state
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(String)

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Waiting for device authorization..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
