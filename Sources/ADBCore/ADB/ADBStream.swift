import Foundation

protocol ADBMessageTransport: Sendable {
    func sendMessage(_ message: ADBMessage) async throws
    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage
}

protocol ADBClientTransport: ADBMessageTransport {
    var isConnected: Bool { get }
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws
    func upgradeToTLS() async throws
    func disconnect()
}

actor ADBStreamInbox {
    private final class WaiterGate: @unchecked Sendable {
        enum State {
            case pending
            case delivered
            case cancelled
            case timedOut
        }

        private let lock = NSLock()
        private var value = State.pending

        var state: State { lock.withLock { value } }

        func claim(_ state: State) -> Bool {
            lock.withLock {
                guard value == .pending else { return false }
                value = state
                return true
            }
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<ADBMessage, Error>
        let gate: WaiterGate
        let timeoutTask: Task<Void, Never>?
    }

    private var messages: [ADBMessage] = []
    private var waiters: [UUID: Waiter] = [:]
    private var terminalError: Error?

    func push(_ message: ADBMessage) {
        while let waiter = waiters.first {
            waiters.removeValue(forKey: waiter.key)
            waiter.value.timeoutTask?.cancel()
            if waiter.value.gate.claim(.delivered) {
                waiter.value.continuation.resume(returning: message)
                return
            }
            switch waiter.value.gate.state {
            case .cancelled:
                waiter.value.continuation.resume(throwing: CancellationError())
            case .timedOut:
                waiter.value.continuation.resume(throwing: ADBError.timeout)
            case .pending, .delivered:
                break
            }
        }
        if terminalError == nil {
            messages.append(message)
        }
    }

    func next(timeout: TimeInterval? = nil) async throws -> ADBMessage {
        try Task.checkCancellation()
        if let timeout, timeout <= 0 { throw ADBError.timeout }

        if !messages.isEmpty {
            return messages.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }

        let id = UUID()
        let gate = WaiterGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    _ = gate.claim(.cancelled)
                    continuation.resume(throwing: CancellationError())
                } else if !messages.isEmpty {
                    continuation.resume(returning: messages.removeFirst())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    let timeoutTask: Task<Void, Never>? = timeout.map { duration in
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(duration))
                            await self?.timeoutWaiter(id)
                        }
                    }
                    waiters[id] = Waiter(continuation: continuation, gate: gate, timeoutTask: timeoutTask)
                }
            }
        } onCancel: {
            if gate.claim(.cancelled) {
                Task { await self.cancelWaiter(id) }
            }
        }
    }

    func finish(throwing error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeoutWaiter(_ id: UUID) {
        guard let waiter = waiters[id], waiter.gate.claim(.timedOut) else { return }
        waiters.removeValue(forKey: id)
        waiter.continuation.resume(throwing: ADBError.timeout)
    }
}

actor ADBMessageRouter {
    private let transport: any ADBMessageTransport
    private var inboxes: [UInt32: ADBStreamInbox] = [:]
    private var pumpTask: Task<Void, Never>?
    private var terminalError: Error?

    init(transport: any ADBMessageTransport) {
        self.transport = transport
    }

    func reset() async {
        let previousPump = pumpTask
        previousPump?.cancel()
        _ = await previousPump?.value
        pumpTask = nil
        terminalError = nil
        let oldInboxes = inboxes.values
        inboxes.removeAll()
        for inbox in oldInboxes {
            await inbox.finish(throwing: ADBError.connectionClosed)
        }
    }

    func register(localId: UInt32) async throws -> ADBStreamInbox {
        if let terminalError {
            throw terminalError
        }
        if let inbox = inboxes[localId] {
            return inbox
        }

        let inbox = ADBStreamInbox()
        inboxes[localId] = inbox
        if pumpTask == nil {
            pumpTask = Task { [weak self] in
                await self?.pumpMessages()
            }
        }
        return inbox
    }

    func unregister(localId: UInt32, error: Error = ADBError.connectionClosed) async {
        if let inbox = inboxes.removeValue(forKey: localId) {
            await inbox.finish(throwing: error)
        }
    }

    func shutdown(error: Error = ADBError.connectionClosed) async {
        let previousPump = pumpTask
        previousPump?.cancel()
        _ = await previousPump?.value
        pumpTask = nil
        terminalError = error
        let currentInboxes = inboxes.values
        inboxes.removeAll()
        for inbox in currentInboxes {
            await inbox.finish(throwing: error)
        }
    }

    private func pumpMessages() async {
        do {
            while !Task.isCancelled {
                let message = try await transport.receiveMessage(timeout: nil)
                if let inbox = inboxes[message.arg1] {
                    await inbox.push(message)
                } else if (message.commandType == .write || message.commandType == .ready),
                          message.arg1 != 0 {

                    try? await transport.sendMessage(
                        .closeMessage(localId: message.arg1, remoteId: message.arg0)
                    )
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            terminalError = error
            let currentInboxes = inboxes.values
            inboxes.removeAll()
            for inbox in currentInboxes {
                await inbox.finish(throwing: error)
            }
        }
        pumpTask = nil
    }
}

/// Логический двунаправленный поток поверх одного соединения ADB.
public final class ADBStream: @unchecked Sendable {
    let localId: UInt32
    let remoteId: UInt32

    private let transport: any ADBMessageTransport
    private let router: ADBMessageRouter
    private let inbox: ADBStreamInbox
    private let stateLock = NSLock()
    private var closed = false
    private var deferredServiceMessages: [ADBMessage] = []
    private var deferredServiceBytes = 0

    public var isClosed: Bool {
        stateLock.withLock { closed }
    }

    init(
        localId: UInt32,
        remoteId: UInt32,
        transport: any ADBMessageTransport,
        router: ADBMessageRouter,
        inbox: ADBStreamInbox
    ) {
        self.localId = localId
        self.remoteId = remoteId
        self.transport = transport
        self.router = router
        self.inbox = inbox
    }

    deinit {
        guard stateLock.withLock({ !closed }) else { return }
        let localId = localId
        let remoteId = remoteId
        let transport = transport
        let router = router
        Task {
            try? await transport.sendMessage(
                .closeMessage(localId: localId, remoteId: remoteId)
            )
            await router.unregister(localId: localId)
        }
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw ADBError.connectionClosed }
        try Task.checkCancellation()
        try await transport.sendMessage(
            ADBMessage.writeMessage(localId: localId, remoteId: remoteId, data: data)
        )
    }

    /// Читает следующее сообщение, адресованное этому потоку.
    public func readMessage(timeout: TimeInterval? = nil) async throws -> ADBMessage {
        guard !isClosed else { throw ADBError.connectionClosed }
        let message = try await inbox.next(timeout: timeout)
        guard message.arg0 == remoteId else {
            throw ADBError.protocolError(
                "Packet remote id \(message.arg0) does not match stream \(remoteId)"
            )
        }
        return message
    }

    func deferServiceMessage(_ message: ADBMessage) throws {
        try stateLock.withLock {
            guard deferredServiceMessages.count < 128,
                  message.data.count <= 8 * 1_024 * 1_024 - deferredServiceBytes else {
                throw ADBError.protocolError("Too many pending service bytes")
            }
            deferredServiceMessages.append(message)
            deferredServiceBytes += message.data.count
        }
    }

    func readServiceMessage() async throws -> (message: ADBMessage, needsAcknowledgement: Bool) {
        guard !isClosed else { throw ADBError.connectionClosed }
        if let deferred = stateLock.withLock({ () -> ADBMessage? in
            guard !deferredServiceMessages.isEmpty else { return nil }
            let message = deferredServiceMessages.removeFirst()
            deferredServiceBytes -= message.data.count
            return message
        }) {
            return (deferred, false)
        }
        return (try await readMessage(timeout: 30), true)
    }

    /// Отправляет закрытие потока и освобождает его маршрут.
    public func close() async throws {
        guard markClosed() else { return }
        do {
            try await transport.sendMessage(
                ADBMessage.closeMessage(localId: localId, remoteId: remoteId)
            )
            await router.unregister(localId: localId)
        } catch {
            await router.unregister(localId: localId, error: error)
            throw error
        }
    }

    public func acknowledgeRemoteClose() async {
        guard markClosed() else { return }
        try? await transport.sendMessage(
            ADBMessage.closeMessage(localId: localId, remoteId: remoteId)
        )
        await router.unregister(localId: localId)
    }

    public func sendReady() async throws {
        guard !isClosed else { throw ADBError.connectionClosed }
        try await transport.sendMessage(
            ADBMessage.readyMessage(localId: localId, remoteId: remoteId)
        )
    }

    private func markClosed() -> Bool {
        stateLock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
    }
}
