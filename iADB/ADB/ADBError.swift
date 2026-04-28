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
            return "Not connected to device"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .connectionClosed:
            return "Connection closed by remote"
        case .timeout:
            return "Connection timed out"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        case .protocolError(let msg):
            return "Protocol error: \(msg)"
        case .authenticationFailed:
            return "Authentication failed — check device authorization"
        case .cryptoError(let msg):
            return "Crypto error: \(msg)"
        case .commandFailed(let msg):
            return "Command failed: \(msg)"
        case .fileTransferFailed(let msg):
            return "File transfer failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        }
    }
}
