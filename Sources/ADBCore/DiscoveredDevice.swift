import Foundation

/// Сетевой адрес устройства, найденный через Bonjour.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16
    public var pairingPort: UInt16?

}

/// Событие поиска беспроводных служб ADB.
public enum DeviceDiscoveryEvent: Equatable, Sendable {
    case ready
    case devices([DiscoveredDevice])
    case failure(String)
}
