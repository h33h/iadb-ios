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

/// Per-stream mailbox used by ``ADBMessageRouter``. A cancelled reader is
/// removed immediately, so cancellation never consumes the next stream packet.
actor ADBStreamInbox {
    private var messages: [ADBMessage] = []
    private var waiters: [UUID: CheckedContinuation<ADBMessage, Error>] = [:]
    private var terminalError: Error?

    func push(_ message: ADBMessage) {
        if let waiter = waiters.first {
            waiters.removeValue(forKey: waiter.key)
            waiter.value.resume(returning: message)
        } else if terminalError == nil {
            messages.append(message)
        }
    }

    func next() async throws -> ADBMessage {
        try Task.checkCancellation()

        if !messages.isEmpty {
            return messages.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !messages.isEmpty {
                    continuation.resume(returning: messages.removeFirst())
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func finish(throwing error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// The ADB connection is multiplexed: packets for every logical stream share
/// one socket. This router is the only post-handshake reader of that socket and
/// dispatches packets by the host/local stream id (`arg1`).
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
                    // The owner cancelled after OPEN or already closed this
                    // stream. Refuse both a late OKAY and further WRTE data so
                    // adbd cannot retain an orphaned service indefinitely.
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

/// Represents an open ADB stream for bidirectional communication.
final class ADBStream: @unchecked Sendable {
    let localId: UInt32
    let remoteId: UInt32

    private let transport: any ADBMessageTransport
    private let router: ADBMessageRouter?
    private let inbox: ADBStreamInbox?
    private let stateLock = NSLock()
    private var closed = false

    var isClosed: Bool {
        stateLock.withLock { closed }
    }

    init(
        localId: UInt32,
        remoteId: UInt32,
        transport: any ADBMessageTransport,
        router: ADBMessageRouter? = nil,
        inbox: ADBStreamInbox? = nil
    ) {
        self.localId = localId
        self.remoteId = remoteId
        self.transport = transport
        self.router = router
        self.inbox = inbox
    }

    deinit {
        guard let router, stateLock.withLock({ !closed }) else { return }
        let localId = localId
        let remoteId = remoteId
        let transport = transport
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

    func writeString(_ string: String) async throws {
        guard let data = string.data(using: .utf8) else {
            throw ADBError.commandFailed("Failed to encode string")
        }
        try await write(data)
    }

    func readMessage() async throws -> ADBMessage {
        guard !isClosed else { throw ADBError.connectionClosed }
        let message: ADBMessage
        if let inbox {
            message = try await inbox.next()
        } else {
            // Kept for isolated stream tests and alternative transports.
            // Production ADBClient streams always use the router-backed inbox.
            message = try await transport.receiveMessage(timeout: nil)
        }
        guard message.arg0 == remoteId else {
            throw ADBError.protocolError(
                "Packet remote id \(message.arg0) does not match stream \(remoteId)"
            )
        }
        return message
    }

    func close() async throws {
        guard markClosed() else { return }
        do {
            try await transport.sendMessage(
                ADBMessage.closeMessage(localId: localId, remoteId: remoteId)
            )
            await router?.unregister(localId: localId)
        } catch {
            await router?.unregister(localId: localId, error: error)
            throw error
        }
    }

    /// Acknowledge a CLSE initiated by adbd and retire the local stream.
    func acknowledgeRemoteClose() async {
        guard markClosed() else { return }
        try? await transport.sendMessage(
            ADBMessage.closeMessage(localId: localId, remoteId: remoteId)
        )
        await router?.unregister(localId: localId)
    }

    func sendReady() async throws {
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
