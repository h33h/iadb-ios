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

    func testConnectToInvalidHostThrows() async {
        let transport = ADBTransport()
        do {
            try await transport.connect(host: "999.999.999.999", port: 5555, timeout: 1)
            XCTFail("Expected error")
        } catch {
            // Should fail with connection error or timeout
            XCTAssertNotNil(error)
        }
    }

    func testConnectTimeout() async {
        let transport = ADBTransport()
        let start = Date()
        do {
            // Connect to non-routable address with short timeout
            try await transport.connect(host: "192.0.2.1", port: 5555, timeout: 1)
            XCTFail("Expected timeout")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            // Should not take much longer than timeout
            XCTAssertLessThan(elapsed, 5.0)
        }
    }
}
