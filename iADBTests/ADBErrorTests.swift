import Foundation
import XCTest
@testable import iADB

final class ADBErrorTests: XCTestCase {

    func testNotConnectedDescription() {
        let error = ADBError.notConnected
        XCTAssertEqual(error.errorDescription, "Not connected to device")
    }

    func testConnectionFailedDescription() {
        let error = ADBError.connectionFailed("refused")
        XCTAssertEqual(error.errorDescription, "Connection failed: refused")
    }

    func testConnectionClosedDescription() {
        let error = ADBError.connectionClosed
        XCTAssertEqual(error.errorDescription, "Connection closed by remote")
    }

    func testTimeoutDescription() {
        let error = ADBError.timeout
        XCTAssertEqual(error.errorDescription, "Connection timed out")
    }

    func testSendFailedDescription() {
        let error = ADBError.sendFailed("broken pipe")
        XCTAssertEqual(error.errorDescription, "Send failed: broken pipe")
    }

    func testReceiveFailedDescription() {
        let error = ADBError.receiveFailed("reset")
        XCTAssertEqual(error.errorDescription, "Receive failed: reset")
    }

    func testProtocolErrorDescription() {
        let error = ADBError.protocolError("bad header")
        XCTAssertEqual(error.errorDescription, "Protocol error: bad header")
    }

    func testAuthenticationFailedDescription() {
        let error = ADBError.authenticationFailed
        XCTAssertEqual(error.errorDescription, "Authentication failed — check device authorization")
    }

    func testCryptoErrorDescription() {
        let error = ADBError.cryptoError("key gen failed")
        XCTAssertEqual(error.errorDescription, "Crypto error: key gen failed")
    }

    func testCommandFailedDescription() {
        let error = ADBError.commandFailed("not found")
        XCTAssertEqual(error.errorDescription, "Command failed: not found")
    }

    func testFileTransferFailedDescription() {
        let error = ADBError.fileTransferFailed("no space")
        XCTAssertEqual(error.errorDescription, "File transfer failed: no space")
    }

    func testInvalidResponseDescription() {
        let error = ADBError.invalidResponse("unexpected")
        XCTAssertEqual(error.errorDescription, "Invalid response: unexpected")
    }

    func testErrorConformsToLocalizedError() {
        let error: LocalizedError = ADBError.timeout
        XCTAssertNotNil(error.errorDescription)
    }
}
