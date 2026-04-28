import Foundation

protocol ADBMessageTransport: Sendable {
    func sendMessage(_ message: ADBMessage) async throws
    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage
}

/// Represents an open ADB stream for bidirectional communication
final class ADBStream: @unchecked Sendable {
    let localId: UInt32
    let remoteId: UInt32
    private let transport: any ADBMessageTransport
    private(set) var isClosed = false

    init(localId: UInt32, remoteId: UInt32, transport: any ADBMessageTransport) {
        self.localId = localId
        self.remoteId = remoteId
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw ADBError.connectionClosed }
        try await transport.sendMessage(
            ADBMessage.writeMessage(localId: localId, remoteId: remoteId, data: data)
        )
    }

    func writeString(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw ADBError.commandFailed("Failed to encode string")
        }
        try await write(data)
    }

    func readMessage() async throws -> ADBMessage {
        guard !isClosed else { throw ADBError.connectionClosed }
        return try await transport.receiveMessage(timeout: nil)
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        try await transport.sendMessage(
            ADBMessage.closeMessage(localId: localId, remoteId: remoteId)
        )
    }

    func sendReady() async throws {
        try await transport.sendMessage(
            ADBMessage.readyMessage(localId: localId, remoteId: remoteId)
        )
    }
}
