import Foundation

/// Represents a saved device connection
struct SavedDevice: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16

    init(name: String = "", host: String, port: UInt16 = 5555) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
    }

    var displayName: String {
        name.isEmpty ? "\(host):\(port)" : name
    }

    var address: String {
        "\(host):\(port)"
    }
}

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
}

struct PairedDevice: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var publicKey: Data
    var lastHost: String

    init(name: String, publicKey: Data, lastHost: String) {
        self.id = UUID()
        self.name = name
        self.publicKey = publicKey
        self.lastHost = lastHost
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
