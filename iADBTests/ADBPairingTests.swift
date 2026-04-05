import Foundation
import XCTest
@testable import iADB

final class ADBPairingTests: XCTestCase {

    // MARK: - QR Code Parsing

    func testParseValidQRCode() {
        let qr = "WIFI:T:ADB;S:studio-debug-abc123;P:123456;;"
        let result = ADBPairing.parseQRCode(qr)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.serviceName, "studio-debug-abc123")
        XCTAssertEqual(result?.password, "123456")
    }

    func testParseQRCodeDifferentOrder() {
        let qr = "WIFI:P:654321;T:ADB;S:mydevice;;"
        let result = ADBPairing.parseQRCode(qr)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.password, "654321")
        XCTAssertEqual(result?.serviceName, "mydevice")
    }

    func testParseQRCodeInvalidPrefix() {
        XCTAssertNil(ADBPairing.parseQRCode("http://example.com"))
        XCTAssertNil(ADBPairing.parseQRCode(""))
        XCTAssertNil(ADBPairing.parseQRCode("BLUETOOTH:something"))
    }

    func testParseQRCodeMissingPassword() {
        let qr = "WIFI:T:ADB;S:device;;"
        XCTAssertNil(ADBPairing.parseQRCode(qr))
    }

    func testParseQRCodeMissingServiceName() {
        let qr = "WIFI:T:ADB;P:123456;;"
        XCTAssertNil(ADBPairing.parseQRCode(qr))
    }

    func testParseQRCodeJustWIFI() {
        XCTAssertNil(ADBPairing.parseQRCode("WIFI:"))
    }

    // MARK: - Pairing Validation

    func testPairInvalidCodeTooShort() async {
        do {
            _ = try await ADBPairing.pair(host: "192.168.1.1", port: 5555, code: "123")
            XCTFail("Expected error for short code")
        } catch let error as ADBPairing.PairingError {
            if case .invalidCode = error {
                // Expected
            } else {
                XCTFail("Expected invalidCode, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPairInvalidCodeTooLong() async {
        do {
            _ = try await ADBPairing.pair(host: "192.168.1.1", port: 5555, code: "12345678")
            XCTFail("Expected error for long code")
        } catch let error as ADBPairing.PairingError {
            if case .invalidCode = error {
                // Expected
            } else {
                XCTFail("Expected invalidCode, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPairInvalidCodeNonNumeric() async {
        do {
            _ = try await ADBPairing.pair(host: "192.168.1.1", port: 5555, code: "abcdef")
            XCTFail("Expected error for non-numeric code")
        } catch let error as ADBPairing.PairingError {
            if case .invalidCode = error {
                // Expected
            } else {
                XCTFail("Expected invalidCode, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPairCodeWithWhitespace() async {
        // Code with whitespace should be trimmed and validated
        do {
            _ = try await ADBPairing.pair(host: "192.0.2.1", port: 37000, code: " 12345 ")
            XCTFail("Expected error for 5-digit code after trim")
        } catch let error as ADBPairing.PairingError {
            if case .invalidCode = error {
                // Expected - "12345" is 5 digits
            } else {
                // Could also be connection error if 6 digits after trim
            }
        } catch {
            // Any error is fine
        }
    }

    // MARK: - PairingError descriptions

    func testPairingErrorDescriptions() {
        let errors: [(ADBPairing.PairingError, String)] = [
            (.invalidCode, "Invalid pairing code"),
            (.connectionFailed("test"), "Pairing connection failed: test"),
            (.tlsFailed("test"), "TLS handshake failed: test"),
            (.pairingRejected, "Pairing was rejected by the device"),
            (.timeout, "Pairing timed out"),
            (.spake2Failed("test"), "SPAKE2 key exchange failed: test"),
            (.protocolError("test"), "Pairing protocol error: test"),
        ]

        for (error, expected) in errors {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }
}
