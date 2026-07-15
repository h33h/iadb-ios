import Foundation

/// All possible ADB-related errors
enum ADBError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case sendFailed(String)
    case receiveFailed(String)
    case protocolError(String)
    case authenticationFailed
    case cryptoError(String)
    case commandFailed(String)
    case fileTransferFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to device")
        case .connectionFailed(let msg):
            return String(localized: "Connection failed: \(msg)")
        case .connectionClosed:
            return String(localized: "Connection closed by remote")
        case .timeout:
            return String(localized: "Connection timed out")
        case .sendFailed(let msg):
            return String(localized: "Send failed: \(msg)")
        case .receiveFailed(let msg):
            return String(localized: "Receive failed: \(msg)")
        case .protocolError(let msg):
            return String(localized: "Protocol error: \(msg)")
        case .authenticationFailed:
            return String(localized: "Authentication failed — check device authorization")
        case .cryptoError(let msg):
            return String(localized: "Crypto error: \(msg)")
        case .commandFailed(let msg):
            return String(localized: "Command failed: \(msg)")
        case .fileTransferFailed(let msg):
            return String(localized: "File transfer failed: \(msg)")
        case .invalidResponse(let msg):
            return String(localized: "Invalid response: \(msg)")
        }
    }
}
