import Foundation

struct Endpoint: Equatable, Codable, Hashable, Sendable {
    var host: String
    var port: UInt16

    var displayValue: String { "\(host):\(port)" }
}

struct DeviceIdentity: Equatable, Codable, Hashable, Sendable {
    static let unknownID = "unknown"

    var stableID: String
    var displayName: String
    var adbFingerprint: String?

    static func resolved(
        from device: DiscoveredDevice,
        pairedDevices: [PairedDevice]
    ) -> Self {
        let paired = ConnectionFeature.State.pairedDevice(
            matching: device,
            in: pairedDevices
        )
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
}

struct DestructiveActionConfirmation: Equatable, Sendable {
    var deviceID: String
    var transportGeneration: Int
    var objectID: String
    var confirmedAt: Date
}

struct RemoteDeviceTarget: Equatable, Sendable {
    var deviceID: String
    var deviceName: String
    var transportGeneration: Int
    var switchedAt: Date
    var isConnected: Bool

    static let unavailable = Self(
        deviceID: DeviceIdentity.unknownID,
        deviceName: String(localized: "Unknown device"),
        transportGeneration: 0,
        switchedAt: .distantPast,
        isConnected: false
    )

    func confirmation(for objectID: String, at date: Date = Date()) -> DestructiveActionConfirmation? {
        guard isConnected, deviceID != DeviceIdentity.unknownID else { return nil }
        return DestructiveActionConfirmation(
            deviceID: deviceID,
            transportGeneration: transportGeneration,
            objectID: objectID,
            confirmedAt: date
        )
    }

    func accepts(_ confirmation: DestructiveActionConfirmation, objectID: String) -> Bool {
        isConnected &&
            confirmation.deviceID == deviceID &&
            confirmation.transportGeneration == transportGeneration &&
            confirmation.objectID == objectID &&
            confirmation.confirmedAt >= switchedAt
    }
}

enum SessionDisconnectReason: Equatable, Sendable {
    case userInitiated
    case transport(String)
    case connectionFailed(String)
    case rebooting
}

enum DeviceTransportState: Equatable, Sendable {
    case noDevice
    case paired
    case connecting
    case connected(endpoint: Endpoint, since: Date)
    case reconnecting(attempt: Int, lastEndpoint: Endpoint?)
    case disconnected(reason: SessionDisconnectReason, lastSeen: Date?)
}

struct DisabledReason: Equatable, Sendable {
    var message: String
}

struct DeviceCapabilities: Equatable, Sendable {
    var canReadRemoteFiles: Bool
    var canWriteRemoteFiles: Bool
    var canRunCommand: Bool
    var canCaptureLogcat: Bool
    var canInstallAPK: Bool
    var canCaptureScreen: Bool
    var canReboot: Bool

    static let offline = Self(
        canReadRemoteFiles: false,
        canWriteRemoteFiles: false,
        canRunCommand: false,
        canCaptureLogcat: false,
        canInstallAPK: false,
        canCaptureScreen: false,
        canReboot: false
    )

    static let connected = Self(
        canReadRemoteFiles: true,
        canWriteRemoteFiles: true,
        canRunCommand: true,
        canCaptureLogcat: true,
        canInstallAPK: true,
        canCaptureScreen: true,
        canReboot: true
    )

    static let disconnectedReason = DisabledReason(
        message: String(localized: "Reconnect the selected Android device to use this action.")
    )
}

enum RemoteWorkspaceSnapshot: String, Equatable, Hashable, Sendable {
    case device
    case files
    case apps
    case logcat
}

struct RemoteSnapshotRelationship: Equatable, Sendable {
    var deviceID: String
    var fetchedAt: Date
    var isStale: Bool
}
