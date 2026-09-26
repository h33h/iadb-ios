import Foundation
@testable import ADBCore

extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

func syncStat(mode: UInt32) -> Data {
    var result = Data("STA2".utf8)
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt64(0))
    result.appendLittleEndian(UInt64(0))
    result.appendLittleEndian(mode)
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt64(0))
    result.appendLittleEndian(Int64(0))
    result.appendLittleEndian(Int64(0))
    result.appendLittleEndian(Int64(0))
    return result
}

func syncDirectoryEntry(name: Data, mode: UInt32, size: UInt64, modificationTime: Int64) -> Data {
    var result = Data("DNT2".utf8)
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt64(0))
    result.appendLittleEndian(UInt64(0))
    result.appendLittleEndian(mode)
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(UInt32(0))
    result.appendLittleEndian(size)
    result.appendLittleEndian(Int64(0))
    result.appendLittleEndian(modificationTime)
    result.appendLittleEndian(Int64(0))
    result.appendLittleEndian(UInt32(name.count))
    result.append(name)
    return result
}

func waitForSyncWrite(_ tag: String, on transport: ScriptedTransport) async throws {
    for _ in 0..<1_000 {
        if transport.sentMessages.contains(where: {
            $0.commandType == .write && syncTag($0.data) == tag
        }) {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ADBError.timeout
}

func syncFrame(_ tag: String, value: UInt32, payload: Data = Data()) -> Data {
    var result = Data(tag.utf8)
    result.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    result.append(payload)
    return result
}

func syncTag(_ data: Data) -> String {
    String(bytes: data.prefix(4), encoding: .utf8) ?? ""
}

func syncValue(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
}

func shellPacket(id: UInt8, payload: Data) -> Data {
    var result = Data([id])
    result.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) })
    result.append(payload)
    return result
}

func waitForOpen(_ destination: String, on transport: ScriptedTransport) async throws -> ADBMessage {
    for _ in 0..<1_000 {
        if let message = transport.sentMessages.first(where: {
            $0.commandType == .open && String(decoding: $0.data.dropLast(), as: UTF8.self) == destination
        }) {
            return message
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ADBError.timeout
}

struct InMemoryIdentity: ADBSigningIdentity {
    let keyOrigin = "memory"

    func publicKeyFingerprint() -> String { "test-fingerprint" }
    func sign(token: Data) throws -> Data { Data(token.reversed()) }
    func adbPublicKey() throws -> Data { Data("test-key\0".utf8) }
}

actor TestPacketQueue {
    private var packets: [ADBMessage] = []
    private var waiters: [UUID: CheckedContinuation<ADBMessage, Error>] = [:]
    private var closed = false

    func enqueue(_ packet: ADBMessage) {
        if let waiter = waiters.first {
            waiters.removeValue(forKey: waiter.key)
            waiter.value.resume(returning: packet)
        } else {
            packets.append(packet)
        }
    }

    func next() async throws -> ADBMessage {
        if !packets.isEmpty { return packets.removeFirst() }
        if closed { throw ADBError.connectionClosed }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func finish() {
        closed = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: ADBError.connectionClosed) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

enum ScriptedTransportEvent: Equatable {
    case sent(ADBCommand?)
    case received(ADBCommand?)
    case tlsUpgrade
}

final class ScriptedTransport: @unchecked Sendable, ADBClientTransport {
    private let queue = TestPacketQueue()
    private let lock = NSLock()
    private let failTLSUpgrade: Bool
    private var sent: [ADBMessage] = []
    private var history: [ScriptedTransportEvent] = []
    private var connected = false
    private var upgrades = 0

    var isConnected: Bool { lock.withLock { connected } }
    var sentMessages: [ADBMessage] { lock.withLock { sent } }
    var upgradeCount: Int { lock.withLock { upgrades } }
    var events: [ScriptedTransportEvent] { lock.withLock { history } }

    init(failTLSUpgrade: Bool = false) {
        self.failTLSUpgrade = failTLSUpgrade
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws {
        lock.withLock { connected = true }
    }

    func upgradeToTLS() async throws {
        lock.withLock {
            upgrades += 1
            history.append(.tlsUpgrade)
        }
        if failTLSUpgrade { throw ADBError.connectionFailed("TLS upgrade failed") }
    }

    func disconnect() {
        lock.withLock { connected = false }
        Task { await queue.finish() }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        guard isConnected else { throw ADBError.notConnected }
        lock.withLock {
            sent.append(message)
            history.append(.sent(message.commandType))
        }
    }

    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage {
        let message = try await queue.next()
        lock.withLock { history.append(.received(message.commandType)) }
        return message
    }

    func enqueue(_ message: ADBMessage) async {
        await queue.enqueue(message)
    }
}
