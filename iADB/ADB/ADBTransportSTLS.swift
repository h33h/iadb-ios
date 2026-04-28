import Foundation
import Security
import os

/// Транспорт для `_adb-tls-connect` порта по STLS-flow:
/// plain TCP → plaintext CNXN → server STLS → client STLS → TLS upgrade → данные.
/// Использует URLSessionStreamTask, потому что NWConnection не умеет TLS-upgrade
/// на уже установленном сокете.
final class ADBTransportSTLS: NSObject, @unchecked Sendable, ADBMessageTransport, URLSessionDelegate, URLSessionTaskDelegate, URLSessionStreamDelegate {
    static let log = Logger(subsystem: "com.iadb.app", category: "stls")

    private var session: URLSession!
    private var task: URLSessionStreamTask?
    private let identity: SecIdentity
    private var receiveBuffer = Data()
    private let bufferLock = NSLock()
    private(set) var isUpgraded = false

    var skipChecksum = false

    var isConnected: Bool {
        guard let task = task else { return false }
        return task.state == .running
    }

    init(identity: SecIdentity) {
        self.identity = identity
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 15) async throws {
        let task = session.streamTask(withHostName: host, port: Int(port))
        self.task = task
        task.resume()
        ADBTransportSTLS.log.info("STLS: TCP connect to \(host, privacy: .public):\(port, privacy: .public)")
    }

    /// TLS upgrade на уже установленном TCP. Сертификат клиента отдаётся через
    /// URLAuthenticationChallenge (см. urlSession:task:didReceive:completionHandler:).
    func upgradeToTLS() async throws {
        guard let task = task else { throw ADBError.notConnected }
        ADBTransportSTLS.log.info("STLS: starting TLS upgrade")
        task.startSecureConnection()
        isUpgraded = true
        skipChecksum = true
        // Маленький запас на handshake. Реально обмен пойдёт при первом read/write.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func disconnect() {
        task?.cancel()
        task = nil
        receiveBuffer.removeAll()
        skipChecksum = false
        isUpgraded = false
    }

    func send(_ data: Data) async throws {
        guard let task = task else { throw ADBError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 30) { error in
                if let error = error {
                    cont.resume(throwing: ADBError.sendFailed(error.localizedDescription))
                } else {
                    cont.resume()
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

        let cmdAscii = String(bytes: [
            UInt8(header.command & 0xFF),
            UInt8((header.command >> 8) & 0xFF),
            UInt8((header.command >> 16) & 0xFF),
            UInt8((header.command >> 24) & 0xFF)
        ], encoding: .ascii) ?? "?"
        ADBTransportSTLS.log.info("STLS hdr cmd=\(cmdAscii, privacy: .public) arg0=\(header.arg0, privacy: .public) arg1=\(header.arg1, privacy: .public) dataLen=\(header.dataLength, privacy: .public)")

        guard header.command ^ header.magic == 0xFFFFFFFF else {
            let hex = headerData.map { String(format: "%02x", $0) }.joined()
            ADBTransportSTLS.log.error("STLS bad header magic: \(hex, privacy: .public)")
            throw ADBError.protocolError(
                "Bad header magic: cmd=\(String(format: "0x%08X", header.command)) magic=\(String(format: "0x%08X", header.magic))"
            )
        }

        var payload = Data()
        if header.dataLength > 0 {
            guard header.dataLength <= ADBMessage.maxPayload else {
                let hex = headerData.map { String(format: "%02x", $0) }.joined()
                ADBTransportSTLS.log.error("STLS payload too large dataLength=\(header.dataLength, privacy: .public) header=\(hex, privacy: .public)")
                throw ADBError.protocolError("Payload too large: \(header.dataLength)")
            }
            ADBTransportSTLS.log.info("STLS reading payload \(header.dataLength, privacy: .public) bytes")
            payload = try await receive(exactly: Int(header.dataLength))
            let preview = payload.prefix(32).map { String(format: "%02x", $0) }.joined()
            ADBTransportSTLS.log.info("STLS payload[0..\(min(32, payload.count), privacy: .public)]=\(preview, privacy: .public)")
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
        guard let task = task else { throw ADBError.notConnected }

        while true {
            bufferLock.lock()
            if receiveBuffer.count >= count {
                // Свежая копия (Data со start=0), чтобы parseHeader не натыкался
                // на slice с нестандартным baseAddress.
                let chunk = Data(receiveBuffer.prefix(count))
                receiveBuffer.removeFirst(count)
                bufferLock.unlock()
                return chunk
            }
            bufferLock.unlock()

            let result: (data: Data?, atEOF: Bool) = try await withCheckedThrowingContinuation { cont in
                task.readData(ofMinLength: 1, maxLength: 65536, timeout: 30) { data, atEOF, error in
                    if let error = error {
                        cont.resume(throwing: ADBError.receiveFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: (data, atEOF))
                    }
                }
            }

            if let chunk = result.data, !chunk.isEmpty {
                bufferLock.lock()
                receiveBuffer.append(chunk)
                let bufLen = receiveBuffer.count
                bufferLock.unlock()
                ADBTransportSTLS.log.debug("STLS read +\(chunk.count, privacy: .public) bytes (buf=\(bufLen, privacy: .public), need=\(count, privacy: .public))")
            }

            if result.atEOF {
                bufferLock.lock()
                let haveEnough = receiveBuffer.count >= count
                bufferLock.unlock()
                if !haveEnough {
                    throw ADBError.connectionClosed
                }
            }
        }
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

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        ADBTransportSTLS.log.info("STLS: auth challenge method=\(method, privacy: .public)")

        switch method {
        case NSURLAuthenticationMethodServerTrust:
            // Принимаем любой server cert (adbd использует self-signed).
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            guard let cert = cert else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let credential = URLCredential(identity: identity, certificates: [cert], persistence: .none)
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
