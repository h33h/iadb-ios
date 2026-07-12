import Foundation
import XCTest
@testable import iADB

final class ADBStreamTests: XCTestCase {

    func testStreamInitialization() {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        XCTAssertEqual(stream.localId, 1)
        XCTAssertEqual(stream.remoteId, 2)
        XCTAssertFalse(stream.isClosed)
    }

    func testStreamCloseSetsClosed() async throws {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        // close() will fail since transport is not connected, but isClosed should be set
        try? await stream.close()
        XCTAssertTrue(stream.isClosed)
    }

    func testStreamDoubleCloseIsNoop() async throws {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        try? await stream.close()
        XCTAssertTrue(stream.isClosed)

        // Second close should not throw
        try? await stream.close()
        XCTAssertTrue(stream.isClosed)
    }

    func testStreamWriteWhenClosedThrows() async {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        try? await stream.close()

        do {
            try await stream.write(Data([1, 2, 3]))
            XCTFail("Expected error")
        } catch {
            guard case ADBError.connectionClosed = error else {
                XCTFail("Expected connectionClosed, got \(error)")
                return
            }
        }
    }

    func testStreamWriteStringWhenClosedThrows() async {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        try? await stream.close()

        do {
            try await stream.writeString("test")
            XCTFail("Expected error")
        } catch {
            guard case ADBError.connectionClosed = error else {
                XCTFail("Expected connectionClosed, got \(error)")
                return
            }
        }
    }

    func testStreamReadMessageWhenClosedThrows() async {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        try? await stream.close()

        do {
            _ = try await stream.readMessage()
            XCTFail("Expected error")
        } catch {
            guard case ADBError.connectionClosed = error else {
                XCTFail("Expected connectionClosed, got \(error)")
                return
            }
        }
    }

    func testStreamWriteWhenNotConnectedThrows() async {
        let transport = ADBTransport()
        let stream = ADBStream(localId: 1, remoteId: 2, transport: transport)

        do {
            try await stream.write(Data([1, 2, 3]))
            XCTFail("Expected error")
        } catch {
            // Should get notConnected from transport
            guard case ADBError.notConnected = error else {
                XCTFail("Expected notConnected, got \(error)")
                return
            }
        }
    }
}

final class ADBClientProtocolTests: XCTestCase {
    func testRouterKeepsConcurrentStreamMessagesSeparated() async throws {
        let transport = MockADBClientTransport()
        let router = ADBMessageRouter(transport: transport)
        let firstInbox = try await router.register(localId: 1)
        let secondInbox = try await router.register(localId: 2)
        let first = ADBStream(
            localId: 1,
            remoteId: 101,
            transport: transport,
            router: router,
            inbox: firstInbox
        )
        let second = ADBStream(
            localId: 2,
            remoteId: 102,
            transport: transport,
            router: router,
            inbox: secondInbox
        )

        await transport.enqueue(.writeMessage(localId: 102, remoteId: 2, data: Data("second".utf8)))
        await transport.enqueue(.writeMessage(localId: 101, remoteId: 1, data: Data("first".utf8)))

        let firstMessage = try await first.readMessage()
        let secondMessage = try await second.readMessage()
        XCTAssertEqual(String(data: firstMessage.data, encoding: .utf8), "first")
        XCTAssertEqual(String(data: secondMessage.data, encoding: .utf8), "second")

        try await first.close()
        try await second.close()
        await router.shutdown()
    }

    func testCancelledStreamReadDoesNotConsumeNextMessage() async throws {
        let transport = MockADBClientTransport()
        let router = ADBMessageRouter(transport: transport)
        let inbox = try await router.register(localId: 1)
        let stream = ADBStream(
            localId: 1,
            remoteId: 101,
            transport: transport,
            router: router,
            inbox: inbox
        )

        let pendingRead = Task { try await stream.readMessage() }
        await Task.yield()
        pendingRead.cancel()
        do {
            _ = try await pendingRead.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        await transport.enqueue(.writeMessage(localId: 101, remoteId: 1, data: Data("kept".utf8)))
        let message = try await stream.readMessage()
        XCTAssertEqual(String(data: message.data, encoding: .utf8), "kept")
        try await stream.close()
        await router.shutdown()
    }

    func testLateOkayForCancelledOpenIsClosedImmediately() async throws {
        let transport = MockADBClientTransport()
        let router = ADBMessageRouter(transport: transport)
        _ = try await router.register(localId: 7)
        await router.unregister(localId: 7, error: CancellationError())

        await transport.enqueue(.readyMessage(localId: 700, remoteId: 7))
        try await waitForSentMessageCount(1, transport: transport)

        let close = try XCTUnwrap(transport.sentMessages.first)
        XCTAssertEqual(close.commandType, .close)
        XCTAssertEqual(close.arg0, 7)
        XCTAssertEqual(close.arg1, 700)
        await router.shutdown()
    }

    func testPushUses64KiBSyncChunksAndAcknowledgesFinalStatus() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport, maxData: ADBMessage.maxPayload)
        let remoteId: UInt32 = 91
        let localId: UInt32 = 1

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId)) // OPEN
        for _ in 0..<4 { // SEND, two DATA frames, DONE
            await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        }
        await transport.enqueue(
            .writeMessage(
                localId: remoteId,
                remoteId: localId,
                data: syncFrame(tag: "OKAY", value: 0)
            )
        )

        try await client.pushData(Data(repeating: 0xAB, count: 65_537), to: "/sdcard/test.bin")

        let writes = transport.sentMessages.filter { $0.commandType == .write }
        XCTAssertEqual(writes.count, 4)
        XCTAssertEqual(syncTag(writes[0].data), "SEND")
        XCTAssertEqual(syncTag(writes[1].data), "DATA")
        XCTAssertEqual(syncValue(writes[1].data), 65_536)
        XCTAssertEqual(writes[1].data.count, 8 + 65_536)
        XCTAssertEqual(syncTag(writes[2].data), "DATA")
        XCTAssertEqual(syncValue(writes[2].data), 1)
        XCTAssertEqual(syncTag(writes[3].data), "DONE")
        XCTAssertTrue(
            transport.sentMessages.contains {
                $0.commandType == .ready && $0.arg0 == localId && $0.arg1 == remoteId
            },
            "The service-level SYNC OKAY WRTE must receive a transport OKAY acknowledgement"
        )
        XCTAssertTrue(transport.sentMessages.contains { $0.commandType == .close })
    }

    func testPullParsesSyncFramesAcrossADBPacketBoundaries() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport, maxData: ADBMessage.maxPayload)
        let remoteId: UInt32 = 92
        let localId: UInt32 = 1
        let serviceBytes = syncFrame(tag: "DATA", value: 5, payload: Data("hello".utf8))
            + syncFrame(tag: "DONE", value: 0)

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId)) // OPEN
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId)) // RECV
        await transport.enqueue(
            .writeMessage(localId: remoteId, remoteId: localId, data: Data(serviceBytes.prefix(3)))
        )
        await transport.enqueue(
            .writeMessage(localId: remoteId, remoteId: localId, data: Data(serviceBytes.dropFirst(3)))
        )

        let result = try await client.pullFile(remotePath: "/sdcard/test.bin")

        XCTAssertEqual(result, Data("hello".utf8))
        let acknowledgements = transport.sentMessages.filter {
            $0.commandType == .ready && $0.arg0 == localId && $0.arg1 == remoteId
        }
        XCTAssertEqual(acknowledgements.count, 2)
        XCTAssertTrue(transport.sentMessages.contains { $0.commandType == .close })
    }

    func testSyncFramingIsIndependentFromNegotiatedADBPayloadSize() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport, maxData: 4_096)
        let remoteId: UInt32 = 95
        let localId: UInt32 = 1

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId)) // OPEN
        // SEND is one packet, 64 KiB DATA spans 17 packets, DONE is one packet.
        for _ in 0..<19 {
            await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        }
        await transport.enqueue(
            .writeMessage(
                localId: remoteId,
                remoteId: localId,
                data: syncFrame(tag: "OKAY", value: 0)
            )
        )

        try await client.pushData(Data(repeating: 0xCD, count: 65_536), to: "/data/local/tmp/a")

        let writes = transport.sentMessages.filter { $0.commandType == .write }
        XCTAssertTrue(writes.allSatisfy { $0.data.count <= 4_096 })
        let serviceBytes = writes.reduce(into: Data()) { $0.append($1.data) }
        let sendLength = Int(syncValue(serviceBytes))
        let dataOffset = 8 + sendLength
        XCTAssertEqual(syncTag(Data(serviceBytes.dropFirst(dataOffset))), "DATA")
        XCTAssertEqual(syncValue(Data(serviceBytes.dropFirst(dataOffset))), 65_536)
        let doneOffset = dataOffset + 8 + 65_536
        XCTAssertEqual(syncTag(Data(serviceBytes.dropFirst(doneOffset))), "DONE")
    }

    func testShellV2ReturnsOutputAndUsesExitStatus() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let remoteId: UInt32 = 93
        let localId: UInt32 = 1
        let response = shellV2Packet(id: 1, payload: Data("hello\n".utf8))
            + shellV2Packet(id: 3, payload: Data([0]))

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(.writeMessage(localId: remoteId, remoteId: localId, data: response))

        let output = try await client.shell("echo hello")
        XCTAssertEqual(output, "hello")
        XCTAssertTrue(transport.sentMessages.contains { $0.commandType == .close })
    }

    func testShellV2ThrowsForNonZeroExitStatus() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let response = shellV2Packet(id: 2, payload: Data("permission denied\n".utf8))
            + shellV2Packet(id: 3, payload: Data([7]))

        await transport.enqueue(.readyMessage(localId: 94, remoteId: 1))
        await transport.enqueue(.writeMessage(localId: 94, remoteId: 1, data: response))

        do {
            _ = try await client.shell("false")
            XCTFail("Expected commandFailed")
        } catch ADBError.commandFailed(let message) {
            XCTAssertTrue(message.contains("Exit status 7"))
            XCTAssertTrue(message.contains("permission denied"))
        }
    }

    func testLegacyShellFallbackStillChecksExitStatus() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)

        await transport.enqueue(.closeMessage(localId: 0, remoteId: 1)) // Reject shell,v2.

        let operation = Task { try await client.shell("echo legacy") }
        try await waitForSentMessageCount(2, transport: transport)
        let legacyOpen = try XCTUnwrap(
            transport.sentMessages.last { $0.commandType == .open && $0.arg0 == 2 }
        )
        let destination = try XCTUnwrap(
            String(data: Data(legacyOpen.data.dropLast()), encoding: .utf8)
        )
        let marker = try XCTUnwrap(extractLegacyMarker(from: destination))

        await transport.enqueue(.readyMessage(localId: 96, remoteId: 2)) // Accept legacy shell.
        await transport.enqueue(
            .writeMessage(
                localId: 96,
                remoteId: 2,
                data: Data("legacy\n\(marker)0\n".utf8)
            )
        )
        await transport.enqueue(.closeMessage(localId: 96, remoteId: 2))

        let output = try await operation.value
        XCTAssertEqual(output, "legacy")
    }

    func testListDirectoryQuotesAndDereferencesSdcardSymlink() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        await transport.enqueue(.readyMessage(localId: 97, remoteId: 1))
        await transport.enqueue(
            .writeMessage(
                localId: 97,
                remoteId: 1,
                data: shellV2Packet(id: 3, payload: Data([0]))
            )
        )

        _ = try await client.listDirectory("/sdcard")

        let open = try XCTUnwrap(transport.sentMessages.first { $0.commandType == .open })
        let destination = try XCTUnwrap(
            String(data: Data(open.data.dropLast()), encoding: .utf8)
        )
        XCTAssertEqual(destination, "shell,v2,raw:ls -la -- '/sdcard/'")
    }

    func testSyncListPreservesNonShellFileNamesAndMetadata() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let remoteId: UInt32 = 98
        let localId: UInt32 = 1
        let path = "/sdcard"
        let largeFileSize: UInt64 = 5_000_000_042
        let statResponse = syncStatV2(mode: 0o040755)
        let listResponse = syncDentV2(
            mode: 0o100644,
            size: largeFileSize,
            modificationTime: 1_700_000_000,
            name: Data("line\nbreak.txt".utf8)
        ) + syncDentV2Done()

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(
            .writeMessage(localId: remoteId, remoteId: localId, data: statResponse)
        )

        let operation = Task { try await client.listDirectoryEntries(path) }
        _ = try await waitForOpenDestination(
            "shell,v2,raw:test -r '/sdcard' && test -x '/sdcard' || exit 13",
            transport: transport
        )
        let shellRemoteID: UInt32 = 198
        let shellLocalID: UInt32 = 2
        await transport.enqueue(
            .readyMessage(localId: shellRemoteID, remoteId: shellLocalID)
        )
        await transport.enqueue(
            .writeMessage(
                localId: shellRemoteID,
                remoteId: shellLocalID,
                data: shellV2Packet(id: 3, payload: Data([0]))
            )
        )
        try await waitForSyncWrite(tag: "LIS2", transport: transport)
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(
            .writeMessage(localId: remoteId, remoteId: localId, data: listResponse)
        )

        let entries = try await operation.value

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "line\nbreak.txt")
        XCTAssertEqual(entries[0].fullPath, "/sdcard/line\nbreak.txt")
        XCTAssertEqual(entries[0].permissions, "-rw-r--r--")
        XCTAssertEqual(entries[0].size, String(largeFileSize))

        let serviceBytes = transport.sentMessages
            .filter { $0.commandType == .write }
            .reduce(into: Data()) { $0.append($1.data) }
        let firstFrameLength = 8 + path.utf8.count
        XCTAssertEqual(syncTag(serviceBytes), "STA2")
        XCTAssertEqual(syncValue(serviceBytes), UInt32(path.utf8.count))
        XCTAssertEqual(String(decoding: serviceBytes.dropFirst(8).prefix(path.utf8.count), as: UTF8.self), path)
        XCTAssertEqual(syncTag(Data(serviceBytes.dropFirst(firstFrameLength))), "LIS2")
        XCTAssertEqual(syncValue(Data(serviceBytes.dropFirst(firstFrameLength))), UInt32(path.utf8.count))
    }

    func testSyncListReportsMissingDirectoryInsteadOfEmptyDirectory() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let remoteId: UInt32 = 99
        let localId: UInt32 = 1

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(
            .writeMessage(
                localId: remoteId,
                remoteId: localId,
                data: syncStatV2(error: 2, mode: 0)
            )
        )

        do {
            _ = try await client.listDirectoryEntries("/missing")
            XCTFail("Expected a missing-directory error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No such file or directory"))
        }

        let serviceWrites = transport.sentMessages.filter { $0.commandType == .write }
        XCTAssertEqual(serviceWrites.count, 1, "LIST_V2 must not run after a failed STAT_V2")
    }

    func testSyncListRejectsRegularFileAsDirectory() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let remoteId: UInt32 = 100
        let localId: UInt32 = 1

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(
            .writeMessage(
                localId: remoteId,
                remoteId: localId,
                data: syncStatV2(mode: 0o100644, size: 12)
            )
        )

        do {
            _ = try await client.listDirectoryEntries("/sdcard/file.txt")
            XCTFail("Expected a not-directory error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Not a directory"))
        }
    }

    func testSyncListReportsUnreadableDirectoryInsteadOfEmptyDirectory() async throws {
        let transport = MockADBClientTransport()
        let client = ADBClient(transport: transport)
        let remoteId: UInt32 = 101
        let localId: UInt32 = 1

        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(.readyMessage(localId: remoteId, remoteId: localId))
        await transport.enqueue(
            .writeMessage(
                localId: remoteId,
                remoteId: localId,
                data: syncStatV2(mode: 0o040000)
            )
        )

        let operation = Task { try await client.listDirectoryEntries("/private") }
        _ = try await waitForOpenDestination(
            "shell,v2,raw:test -r '/private' && test -x '/private' || exit 13",
            transport: transport
        )
        let shellRemoteID: UInt32 = 201
        let shellLocalID: UInt32 = 2
        await transport.enqueue(
            .readyMessage(localId: shellRemoteID, remoteId: shellLocalID)
        )
        await transport.enqueue(
            .writeMessage(
                localId: shellRemoteID,
                remoteId: shellLocalID,
                data: shellV2Packet(id: 3, payload: Data([13]))
            )
        )

        do {
            _ = try await operation.value
            XCTFail("Expected a permission-denied error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"))
        }

        XCTAssertFalse(
            transport.sentMessages.contains {
                $0.commandType == .write && syncTag($0.data) == "LIS2"
            },
            "LIST_V2 must not run when the shell user cannot open the directory"
        )
    }

    func testShellQuoteProtectsMetacharacters() {
        XCTAssertEqual(adbShellQuote(""), "''")
        XCTAssertEqual(adbShellQuote("simple path"), "'simple path'")
        XCTAssertEqual(adbShellQuote("a'b$(reboot)`id`"), "'a'\\''b$(reboot)`id`'")
    }

    func testRequestSerializerPropagatesCallerCancellation() async throws {
        let serializer = RequestSerializer()
        let started = expectation(description: "operation started")
        let operation = Task {
            try await serializer.run {
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "unexpected"
            }
        }

        await fulfillment(of: [started], timeout: 1)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let nextValue = try await serializer.run { "next" }
        XCTAssertEqual(nextValue, "next")
    }

    func testTransportWriteSerializerPropagatesCallerCancellation() async throws {
        let serializer = ADBTransportWriteSerializer()
        let started = expectation(description: "write started")
        let operation = Task {
            try await serializer.run {
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

        await fulfillment(of: [started], timeout: 1)
        operation.cancel()
        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        try await serializer.run {}
    }
}

private actor MockADBMessageQueue {
    private var messages: [ADBMessage] = []
    private var waiters: [UUID: CheckedContinuation<ADBMessage, Error>] = [:]
    private var finished = false

    func enqueue(_ message: ADBMessage) {
        if let waiter = waiters.first {
            waiters.removeValue(forKey: waiter.key)
            waiter.value.resume(returning: message)
        } else {
            messages.append(message)
        }
    }

    func next() async throws -> ADBMessage {
        if !messages.isEmpty { return messages.removeFirst() }
        if finished { throw ADBError.connectionClosed }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func finish() {
        finished = true
        let current = waiters.values
        waiters.removeAll()
        current.forEach { $0.resume(throwing: ADBError.connectionClosed) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class MockADBClientTransport: @unchecked Sendable, ADBClientTransport {
    private let queue = MockADBMessageQueue()
    private let lock = NSLock()
    private var sent: [ADBMessage] = []
    private var connected = true

    var sentMessages: [ADBMessage] { lock.withLock { sent } }
    var isConnected: Bool { lock.withLock { connected } }

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws {
        lock.withLock { connected = true }
    }

    func upgradeToTLS() async throws {}

    func disconnect() {
        lock.withLock { connected = false }
        Task { await queue.finish() }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        guard isConnected else { throw ADBError.notConnected }
        lock.withLock { sent.append(message) }
    }

    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage {
        try await queue.next()
    }

    func enqueue(_ message: ADBMessage) async {
        await queue.enqueue(message)
    }
}

private func syncFrame(tag: String, value: UInt32, payload: Data = Data()) -> Data {
    var result = Data(tag.utf8)
    result.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    result.append(payload)
    return result
}

private func syncStatV2(
    error: UInt32 = 0,
    mode: UInt32,
    size: UInt64 = 0,
    modificationTime: Int64 = 0
) -> Data {
    var result = Data("STA2".utf8)
    result.appendLittleEndian(error)
    result.appendLittleEndian(UInt64(0)) // dev
    result.appendLittleEndian(UInt64(0)) // ino
    result.appendLittleEndian(mode)
    result.appendLittleEndian(UInt32(0)) // nlink
    result.appendLittleEndian(UInt32(0)) // uid
    result.appendLittleEndian(UInt32(0)) // gid
    result.appendLittleEndian(size)
    result.appendLittleEndian(Int64(0)) // atime
    result.appendLittleEndian(modificationTime)
    result.appendLittleEndian(Int64(0)) // ctime
    return result
}

private func syncDentV2(
    error: UInt32 = 0,
    mode: UInt32,
    size: UInt64,
    modificationTime: Int64,
    name: Data
) -> Data {
    var result = Data("DNT2".utf8)
    result.appendLittleEndian(error)
    result.appendLittleEndian(UInt64(0)) // dev
    result.appendLittleEndian(UInt64(0)) // ino
    result.appendLittleEndian(mode)
    result.appendLittleEndian(UInt32(0)) // nlink
    result.appendLittleEndian(UInt32(0)) // uid
    result.appendLittleEndian(UInt32(0)) // gid
    result.appendLittleEndian(size)
    result.appendLittleEndian(Int64(0)) // atime
    result.appendLittleEndian(modificationTime)
    result.appendLittleEndian(Int64(0)) // ctime
    result.appendLittleEndian(UInt32(name.count))
    result.append(name)
    return result
}

private func syncDentV2Done() -> Data {
    Data("DONE".utf8) + Data(repeating: 0, count: 72)
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private func syncTag(_ data: Data) -> String {
    String(bytes: data.prefix(4), encoding: .utf8) ?? ""
}

private func syncValue(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
}

private func shellV2Packet(id: UInt8, payload: Data) -> Data {
    var result = Data([id])
    result.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) })
    result.append(payload)
    return result
}

private func waitForSentMessageCount(
    _ count: Int,
    transport: MockADBClientTransport
) async throws {
    for _ in 0..<1_000 {
        if transport.sentMessages.count >= count { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ADBError.timeout
}

private func waitForOpenDestination(
    _ destination: String,
    transport: MockADBClientTransport
) async throws -> ADBMessage {
    for _ in 0..<1_000 {
        if let message = transport.sentMessages.first(where: { message in
            guard message.commandType == .open else { return false }
            return String(decoding: message.data.dropLast(), as: UTF8.self) == destination
        }) {
            return message
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ADBError.timeout
}

private func waitForSyncWrite(
    tag: String,
    transport: MockADBClientTransport
) async throws {
    for _ in 0..<1_000 {
        if transport.sentMessages.contains(where: {
            $0.commandType == .write && syncTag($0.data) == tag
        }) {
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ADBError.timeout
}

private func extractLegacyMarker(from command: String) -> String? {
    guard let start = command.range(of: "__IADB_EXIT_") else { return nil }
    let remainder = command[start.upperBound...]
    guard let end = remainder.range(of: "__") else { return nil }
    return String(command[start.lowerBound..<end.upperBound])
}
