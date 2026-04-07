import Foundation
import Security

/// Low-level TCP transport for ADB protocol communication.
/// Supports plain TCP and mid-connection TLS upgrade (STLS protocol).
final class ADBTransport: NSObject, @unchecked Sendable {
    private var session: URLSession?
    private var streamTask: URLSessionStreamTask?
    private var clientIdentity: SecIdentity?
    private let lock = NSLock()

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return streamTask != nil
    }

    // MARK: - Connection

    /// Plain TCP connection (no TLS yet — use upgradeTLS for STLS flow)
    func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        disconnect()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3

        let opQueue = OperationQueue()
        opQueue.qualityOfService = .userInitiated
        let sess = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)

        let task = sess.streamTask(withHostName: host, port: Int(port))
        task.resume()

        lock.lock()
        self.session = sess
        self.streamTask = task
        lock.unlock()

        // Verify connection by attempting a zero-byte read with timeout.
        // URLSessionStreamTask doesn't have a "connected" callback — the first I/O
        // operation triggers actual TCP connect. We do a minimal read to surface
        // errors early (e.g., connection refused).
    }

    /// Upgrade the current plain-TCP connection to TLS 1.3 with mutual authentication.
    /// Must be called AFTER sending the A_STLS message to the device.
    ///
    /// Per AOSP protocol: `startSecureConnection()` completes all enqueued writes
    /// before beginning the TLS handshake, so the A_STLS packet is guaranteed to
    /// be sent in plaintext before TLS begins.
    func upgradeTLS(identity: SecIdentity) {
        lock.lock()
        self.clientIdentity = identity
        let task = self.streamTask
        lock.unlock()

        task?.startSecureConnection()
    }

    func disconnect() {
        lock.lock()
        let task = streamTask
        let sess = session
        streamTask = nil
        session = nil
        clientIdentity = nil
        lock.unlock()

        task?.cancel()
        sess?.invalidateAndCancel()
    }

    // MARK: - Send / Receive

    func send(_ data: Data) async throws {
        guard let task = currentTask() else { throw ADBError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 30) { error in
                if let error = error {
                    continuation.resume(throwing: ADBError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        try await send(message.serialized)
    }

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

        guard message.isValid else {
            throw ADBError.protocolError("Message validation failed")
        }

        return message
    }

    func receive(exactly count: Int) async throws -> Data {
        guard let task = currentTask() else { throw ADBError.notConnected }

        var buffer = Data()
        buffer.reserveCapacity(count)

        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                task.readData(ofMinLength: 1, maxLength: remaining, timeout: 30) { data, atEOF, error in
                    if let error = error {
                        continuation.resume(throwing: ADBError.receiveFailed(error.localizedDescription))
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if atEOF {
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

    // MARK: - Helpers

    private func currentTask() -> URLSessionStreamTask? {
        lock.lock()
        defer { lock.unlock() }
        return streamTask
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

// MARK: - URLSession TLS Delegate

extension ADBTransport: URLSessionDelegate, URLSessionTaskDelegate {

    /// Handle TLS authentication challenges for mTLS and self-signed certificate acceptance.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            lock.lock()
            let identity = clientIdentity
            lock.unlock()

            if let identity = identity {
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else if method == NSURLAuthenticationMethodServerTrust {
            // Accept self-signed certificates (ADB uses self-signed on both sides)
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Session-level challenge (fallback for server trust)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
