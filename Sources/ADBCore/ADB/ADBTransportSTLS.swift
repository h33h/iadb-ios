import Foundation
import Security
import os

private final class ADBURLSessionDelegateProxy: NSObject, @unchecked Sendable,
    URLSessionDelegate,
    URLSessionTaskDelegate,
    URLSessionStreamDelegate {
    weak var owner: ADBTransportSTLS?

    init(owner: ADBTransportSTLS) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        owner?.handleChallenge(challenge, completionHandler: completionHandler)
            ?? completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        owner?.handleChallenge(challenge, completionHandler: completionHandler)
            ?? completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

actor ADBTransportWriteSerializer {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Void, Error> {
            _ = await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

final class ADBTransportSTLS: NSObject, @unchecked Sendable, ADBClientTransport {
    static let log = Logger(subsystem: "com.iadb.adbcore", category: "stls")

    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private let identity: SecIdentity
    private lazy var delegateProxy = ADBURLSessionDelegateProxy(owner: self)
    private let stateLock = NSLock()
    private let writeSerializer = ADBTransportWriteSerializer()
    private var receiveBuffer = Data()
    private var connectionAlive = false
    var skipChecksum = false

    var isConnected: Bool {
        stateLock.withLock { connectionAlive && task?.state == .running }
    }

    init(identity: SecIdentity) {
        self.identity = identity
        super.init()
    }

    deinit {
        let resources = stateLock.withLock { (task, session) }
        resources.0?.cancel()
        resources.1?.invalidateAndCancel()
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 15) async throws {
        disconnect()
        try Task.checkCancellation()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 60)
        let session = URLSession(
            configuration: configuration,
            delegate: delegateProxy,
            delegateQueue: nil
        )
        let task = session.streamTask(withHostName: host, port: Int(port))
        stateLock.withLock {
            self.session = session
            self.task = task
            self.connectionAlive = true
        }
        task.resume()
        Self.log.info("STLS: TCP connect endpoint=\(host, privacy: .private(mask: .hash))")
    }

    func upgradeToTLS() async throws {
        guard let task = stateLock.withLock({ task }) else {
            throw ADBError.notConnected
        }
        try Task.checkCancellation()
        Self.log.info("STLS: starting TLS upgrade")
        task.startSecureConnection()
        stateLock.withLock {
            skipChecksum = true
        }

        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func disconnect() {
        let resources = stateLock.withLock { () -> (URLSessionStreamTask?, URLSession?) in
            let resources = (task, session)
            task = nil
            session = nil
            receiveBuffer.removeAll(keepingCapacity: false)
            connectionAlive = false
            skipChecksum = false
            return resources
        }
        resources.0?.cancel()
        resources.1?.invalidateAndCancel()
    }

    func send(_ data: Data) async throws {
        guard let task = stateLock.withLock({ task }) else {
            throw ADBError.notConnected
        }

        try await writeSerializer.run {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.write(data, timeout: 30) { error in
                        if let error {
                            self.markConnectionFailed(ifCurrent: task)
                            if (error as NSError).code == NSURLErrorCancelled {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: ADBError.sendFailed(error.localizedDescription))
                            }
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } onCancel: {
                task.cancel()
            }
        }
        guard isCurrent(task) else { throw ADBError.connectionClosed }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        try await send(message.serialized)
    }

    func receiveMessage(timeout: TimeInterval? = nil) async throws -> ADBMessage {
        guard let currentTask = stateLock.withLock({ task }) else {
            throw ADBError.notConnected
        }
        do {
            if let timeout {
                return try await withTimeout(timeout) {
                    try await self.receiveMessageWithoutTimeout(on: currentTask)
                }
            }
            return try await receiveMessageWithoutTimeout(on: currentTask)
        } catch {
            if !(error is CancellationError) {

                markConnectionFailed(ifCurrent: currentTask)
            }
            throw error
        }
    }

    private func receiveMessageWithoutTimeout(on currentTask: URLSessionStreamTask) async throws -> ADBMessage {
        let headerData = try await receive(exactly: ADBMessage.headerSize, on: currentTask)

        guard let header = ADBMessage.parseHeader(from: headerData) else {
            throw ADBError.protocolError("Invalid message header")
        }

        let commandName = String(bytes: [
            UInt8(header.command & 0xFF),
            UInt8((header.command >> 8) & 0xFF),
            UInt8((header.command >> 16) & 0xFF),
            UInt8((header.command >> 24) & 0xFF)
        ], encoding: .ascii) ?? "?"
        Self.log.debug(
            "STLS header command=\(commandName, privacy: .private) length=\(header.dataLength, privacy: .private)"
        )

        guard header.command ^ header.magic == 0xFFFFFFFF else {
            Self.log.error("STLS received a header with invalid magic")
            throw ADBError.protocolError(
                "Bad header magic: cmd=\(String(format: "0x%08X", header.command)) "
                    + "magic=\(String(format: "0x%08X", header.magic))"
            )
        }

        var payload = Data()
        if header.dataLength > 0 {
            guard header.dataLength <= ADBMessage.maxPayload else {
                Self.log.error("STLS payload exceeds negotiated maximum")
                throw ADBError.protocolError("Payload too large: \(header.dataLength)")
            }
            payload = try await receive(exactly: Int(header.dataLength), on: currentTask)
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

        guard isCurrent(currentTask) else { throw ADBError.connectionClosed }
        let shouldSkipChecksum = stateLock.withLock { skipChecksum }
        guard message.isValid(skipChecksum: shouldSkipChecksum) else {
            throw ADBError.protocolError("Message validation failed")
        }

        if message.commandType == .connect && message.arg0 >= ADBMessage.version {
            stateLock.withLock {
                if task === currentTask { skipChecksum = true }
            }
        }
        return message
    }

    private func receive(exactly count: Int, on currentTask: URLSessionStreamTask) async throws -> Data {
        guard count >= 0 else {
            throw ADBError.protocolError("Negative receive length")
        }

        while true {
            try Task.checkCancellation()
            guard isCurrent(currentTask) else { throw ADBError.connectionClosed }
            if let buffered = stateLock.withLock({ () -> Data? in
                guard task === currentTask else { return nil }
                guard receiveBuffer.count >= count else { return nil }
                let result = Data(receiveBuffer.prefix(count))
                receiveBuffer.removeFirst(count)
                return result
            }) {
                return buffered
            }

            let result: (data: Data?, atEOF: Bool) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in

                    currentTask.readData(ofMinLength: 1, maxLength: 65_536, timeout: 0) { data, atEOF, error in
                        if let error {
                            self.markConnectionFailed(ifCurrent: currentTask)
                            if (error as NSError).code == NSURLErrorCancelled {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: ADBError.receiveFailed(error.localizedDescription))
                            }
                        } else {
                            continuation.resume(returning: (data, atEOF))
                        }
                    }
                }
            } onCancel: {

                currentTask.cancel()
            }

            guard isCurrent(currentTask) else { throw ADBError.connectionClosed }
            if let data = result.data, !data.isEmpty {
                stateLock.withLock {
                    if task === currentTask { receiveBuffer.append(data) }
                }
            }
            if result.atEOF {
                let hasEnoughData = stateLock.withLock { receiveBuffer.count >= count }
                if !hasEnoughData {
                    markConnectionFailed(ifCurrent: currentTask)
                    throw ADBError.connectionClosed
                }
            }
        }
    }

    private func isCurrent(_ expected: URLSessionStreamTask) -> Bool {
        stateLock.withLock { task === expected }
    }

    private func markConnectionFailed(ifCurrent expected: URLSessionStreamTask) {
        stateLock.withLock {
            if task === expected { connectionAlive = false }
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeout > 0 else { throw ADBError.timeout }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ADBError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ADBError.timeout
            }
            return result
        }
    }

    /// Принимает самоподписанный сертификат по модели ADB Wi-Fi без закрепления ключа сервера.
    fileprivate func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        Self.log.debug("STLS authentication challenge: \(method, privacy: .private)")

        switch method {
        case NSURLAuthenticationMethodServerTrust:

            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            guard let certificate else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: [certificate], persistence: .none)
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
