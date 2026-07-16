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
    var cpuAbi: String = ""
    var deviceName: String = ""
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

struct PairedDevice: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var guid: String
    var lastHost: String
    var lastPort: UInt16?
    /// Fingerprint of the iADB public key used when this device was paired.
    var identityFingerprint: String?
    /// Set after Android explicitly rejects this host identity. The record is
    /// kept so the user can pair the same device again without losing its name.
    var requiresPairing: Bool
    /// Persistent mDNS identity derived from Android's ADB_DEVICE_GUID.
    /// It is authenticated by the pairing-code exchange; host/port are only
    /// mutable network locators and must never identify a saved device.
    var serviceName: String?

    init(
        id: UUID = UUID(),
        name: String,
        guid: String,
        lastHost: String,
        lastPort: UInt16? = nil,
        identityFingerprint: String? = nil,
        requiresPairing: Bool = false,
        serviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.guid = guid
        self.lastHost = lastHost
        self.lastPort = lastPort
        self.identityFingerprint = identityFingerprint
        self.requiresPairing = requiresPairing
        self.serviceName = serviceName
    }

    var publicKey: Data { Data(guid.utf8) }

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

}
