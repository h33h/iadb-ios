import Foundation
import Network
import Security
import os

/// Low-level TCP transport for ADB protocol communication.
///
/// Поддерживает прямое TLS-подключение (mTLS) для _adb-tls-connect порта
/// и plain TCP для fallback-сценариев.
final class ADBTransport: @unchecked Sendable, ADBMessageTransport {
    static let log = Logger(subsystem: "com.iadb.app", category: "transport")

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.iadb.transport", qos: .userInitiated)

    /// После TLS Android шлёт dataCRC32=0 (ADB v0x01000001 — TLS гарантирует целостность)
    var skipChecksum = false

    var isConnected: Bool {
        connection?.state == .ready
    }

    // MARK: - Connection

    /// Прямое mTLS-подключение для Android 11+ Wireless Debugging.
    /// Порт _adb-tls-connect принимает TLS сразу — без STLS-хендшейка.
    func connectTLS(host: String, port: UInt16, identity: SecIdentity, timeout: TimeInterval = 30) async throws {
        disconnect()

        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completionHandler in completionHandler(true) },
            DispatchQueue.global(qos: .userInitiated)
        )

        guard let secIdentity = sec_identity_create(identity) else {
            ADBTransport.log.error("connectTLS: sec_identity_create returned nil")
            throw ADBError.cryptoError("Failed to create sec_identity_t for TLS")
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )
        ADBTransport.log.info("connectTLS: identity set OK, starting connection to \(host, privacy: .public):\(port, privacy: .public)")

        let parameters = NWParameters(tls: tlsOptions)

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn

        try await startConnection(conn, timeout: timeout)
        skipChecksum = true
    }

    /// Plain TCP без TLS (fallback для legacy-устройств).
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
                case .setup:
                    ADBTransport.log.debug("NWConnection state: setup")
                case .preparing:
                    ADBTransport.log.debug("NWConnection state: preparing (DNS/TCP/TLS in progress)")
                case .ready:
                    ADBTransport.log.info("NWConnection state: ready (TLS handshake done)")
                    safeResume { continuation.resume() }
                case .waiting(let error):
                    // NWConnection может зависнуть в .waiting на self-signed TLS,
                    // но если ждём слишком долго — реальная причина в error.
                    ADBTransport.log.error("NWConnection state: waiting, error=\(error.localizedDescription, privacy: .public)")
                case .failed(let error):
                    ADBTransport.log.error("NWConnection state: failed, error=\(error.localizedDescription, privacy: .public)")
                    safeResume { continuation.resume(throwing: ADBError.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    ADBTransport.log.info("NWConnection state: cancelled")
                    safeResume { continuation.resume(throwing: ADBError.connectionClosed) }
                @unknown default:
                    break
                }
            }
            conn.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + timeout) {
                safeResume {
                    ADBTransport.log.error("NWConnection: timeout after \(timeout, privacy: .public)s, cancelling")
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
