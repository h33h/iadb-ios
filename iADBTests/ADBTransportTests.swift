import Foundation
import XCTest
@testable import iADB

final class ADBTransportTests: XCTestCase {

    func testInitiallyNotConnected() {
        let transport = ADBTransport()
        XCTAssertFalse(transport.isConnected)
    }

    func testSendWhenNotConnectedThrows() async {
        let transport = ADBTransport()
        do {
            try await transport.send(Data([1, 2, 3]))
            XCTFail("Expected notConnected error")
        } catch {
            guard case ADBError.notConnected = error else {
                XCTFail("Expected notConnected, got \(error)")
                return
            }
        }
    }

    func testSendMessageWhenNotConnectedThrows() async {
        let transport = ADBTransport()
        let msg = ADBMessage(command: .ready, arg0: 0, arg1: 0)
        do {
            try await transport.sendMessage(msg)
            XCTFail("Expected notConnected error")
        } catch {
            guard case ADBError.notConnected = error else {
                XCTFail("Expected notConnected, got \(error)")
                return
            }
        }
    }

    func testReceiveMessageWhenNotConnectedThrows() async {
        let transport = ADBTransport()
        do {
            _ = try await transport.receiveMessage()
            XCTFail("Expected notConnected error")
        } catch {
            guard case ADBError.notConnected = error else {
                XCTFail("Expected notConnected, got \(error)")
                return
            }
        }
    }

    func testDisconnectWhenNotConnected() {
        let transport = ADBTransport()
        // Should not crash
        transport.disconnect()
        XCTAssertFalse(transport.isConnected)
    }

    func testDisconnectMultipleTimes() {
        let transport = ADBTransport()
        transport.disconnect()
        transport.disconnect()
        transport.disconnect()
        XCTAssertFalse(transport.isConnected)
    }

    func testConnectToInvalidHostFailsOnIO() async {
        // URLSessionStreamTask connects lazily — connect() itself succeeds,
        // but the first I/O operation surfaces the DNS/network error.
        let transport = ADBTransport()
        try? await transport.connect(host: "999.999.999.999", port: 5555, timeout: 1)
        XCTAssertTrue(transport.isConnected, "Transport should report connected (task created)")

        do {
            _ = try await transport.receiveMessage(timeout: 5)
            XCTFail("Expected error on I/O to invalid host")
        } catch {
            XCTAssertNotNil(error)
        }
        transport.disconnect()
    }

    func testConnectThenDisconnect() async {
        // Verify that connect + disconnect cycle works without crash
        let transport = ADBTransport()
        try? await transport.connect(host: "192.0.2.1", port: 5555, timeout: 1)
        XCTAssertTrue(transport.isConnected)
        transport.disconnect()
        XCTAssertFalse(transport.isConnected)
    }
}
