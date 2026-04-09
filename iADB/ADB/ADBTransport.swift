import Foundation
import Network
import Security

/// Low-level TCP transport for ADB protocol communication.
///
/// Uses NWConnection with a custom NWProtocolFramer (ADBSTLSFramer) that handles
/// the STLS (StartTLS) protocol upgrade transparently. The connection flow:
/// 1. Plain TCP connect → framer sends CNXN → receives A_STLS → sends A_STLS
/// 2. Framer dynamically adds TLS 1.3 to the protocol stack
/// 3. TLS handshake completes → NWConnection enters .ready
/// 4. All subsequent I/O is encrypted via TLS
final class ADBTransport: @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.iadb.transport", qos: .userInitiated)

    /// When true, skip checksum validation on received messages.
    /// Set after STLS/TLS upgrade — ADB version 0x01000001 allows the device
    /// to send dataCRC32 = 0 since TLS already guarantees integrity.
    var skipChecksum = false

    var isConnected: Bool {
        connection?.state == .ready
    }

    // MARK: - Connection

    /// Connect to an ADB device with automatic STLS TLS upgrade.
    /// The STLS protocol negotiation (CNXN → STLS → TLS handshake) is handled
    /// internally by ADBSTLSFramer. When this method returns, TLS is established.
    func connectSTLS(host: String, port: UInt16, identity: SecIdentity, timeout: TimeInterval = 30) async throws {
        disconnect()

        // Configure the STLS framer with the client identity for mTLS
        ADBSTLSFramer.clientIdentity = identity

        // Build protocol stack: App ↔ ADBSTLSFramer ↔ TLS (added dynamically) ↔ TCP
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        let framerOptions = NWProtocolFramer.Options(definition: ADBSTLSFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn

        try await startConnection(conn, timeout: timeout)
        skipChecksum = true
    }

    /// Plain TCP connection without STLS (fallback for legacy devices).
    func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        disconnect()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn

        try await startConnection(conn, timeout: timeout)
    }

    private func startConnection(_ conn: NWConnection, timeout: TimeInterval) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            func safeResume(_ block: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                block()
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    safeResume { continuation.resume() }
                case .waiting:
                    // NWConnection may enter .waiting during TLS handshake
                    // with self-signed certs — wait for .ready.
                    break
                case .failed(let error):
                    safeResume { continuation.resume(throwing: ADBError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    safeResume { continuation.resume(throwing: ADBError.connectionClosed) }
                default:
                    break
                }
            }
            conn.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + timeout) {
                safeResume {
                    conn.cancel()
                    continuation.resume(throwing: ADBError.timeout)
                }
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        skipChecksum = false
    }

    // MARK: - Send / Receive

    func send(_ data: Data) async throws {
        guard let conn = connection else {
            throw ADBError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: ADBError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        try await send(message.serialized)
    }

    /// Receive a message with optional timeout (default: no timeout)
    func receiveMessage(timeout: TimeInterval? = nil) async throws -> ADBMessage {
        if let timeout = timeout {
            return try await withTimeout(timeout) {
                try await self._receiveMessage()
            }
        }
        return try await _receiveMessage()
    }

    private func _receiveMessage() async throws -> ADBMessage {
        let headerData = try await receive(exactly: ADBMessage.headerSize)

        guard let header = ADBMessage.parseHeader(from: headerData) else {
            throw ADBError.protocolError("Invalid message header")
        }

        var payload = Data()
        if header.dataLength > 0 {
            guard header.dataLength <= ADBMessage.maxPayload else {
                throw ADBError.protocolError("Payload too large: \(header.dataLength)")
            }
            payload = try await receive(exactly: Int(header.dataLength))
        }

        let message = ADBMessage(
            command: header.command,
            arg0: header.arg0,
            arg1: header.arg1,
            dataLength: header.dataLength,
            dataCRC32: header.dataCRC32,
            magic: header.magic,
            data: payload
        )

        guard message.isValid(skipChecksum: skipChecksum) else {
            throw ADBError.protocolError("Message validation failed")
        }

        return message
    }

    private func receive(exactly count: Int) async throws -> Data {
        guard let conn = connection else {
            throw ADBError.notConnected
        }

        var buffer = Data()
        buffer.reserveCapacity(count)

        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: ADBError.receiveFailed(error.localizedDescription))
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: ADBError.connectionClosed)
                    } else {
                        continuation.resume(throwing: ADBError.receiveFailed("No data received"))
                    }
                }
            }
            buffer.append(chunk)
        }

        return buffer
    }

    private func withTimeout<T: Sendable>(_ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ADBError.timeout
            }
            guard let result = try await group.next() else {
                throw ADBError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}
