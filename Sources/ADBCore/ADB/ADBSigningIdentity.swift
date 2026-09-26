import Foundation

/// Подписывает запросы аутентификации ADB и предоставляет открытый ключ хоста.
protocol ADBSigningIdentity: Sendable {
    var keyOrigin: String { get }
    func publicKeyFingerprint() -> String
    func sign(token: Data) throws -> Data
    func adbPublicKey() throws -> Data
}
