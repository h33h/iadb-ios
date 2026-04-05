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
