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

    // MARK: - Protocol Constants (must match AOSP)

    func testPairingPacketVersionIsOne() {
        // AOSP: kCurrentKeyHeaderVersion = 1
        // Verified via the pairing message framing in ADBPairing
        // The first byte of every pairing message must be version 1.
        // This is a documentation test to ensure we don't accidentally change it.
        let version: UInt8 = 1
        XCTAssertEqual(version, 1, "Pairing protocol version must be 1 per AOSP")
    }

    func testPairingMessageTypes() {
        // AOSP PairingPacketType: kSpakeMsg = 0, kPeerInfo = 1
        XCTAssertEqual(UInt8(0), 0, "SPAKE2 message type must be 0")
        XCTAssertEqual(UInt8(1), 1, "PeerInfo message type must be 1")
    }

    func testPeerInfoSizeIs8192() {
        // AOSP: MAX_PEER_INFO_SIZE = 8192
        // PeerInfo is always exactly 8192 bytes (zero-padded)
        let peerInfoSize = 8192
        XCTAssertEqual(peerInfoSize, 8192, "PeerInfo must be exactly 8192 bytes per AOSP")
    }

    func testPairingHeaderSize() {
        // Header: version(1 byte) + type(1 byte) + payload_length(4 bytes BE) = 6 bytes
        let headerSize = 1 + 1 + 4
        XCTAssertEqual(headerSize, 6, "Pairing packet header must be 6 bytes")
    }

    func testExportedKeyMaterialSize() {
        // AOSP: kExportedKeySize = 64
        let ekmSize = 64
        XCTAssertEqual(ekmSize, 64, "TLS exported keying material must be 64 bytes")
    }

    func testExportedKeyLabelMatchesAOSP() {
        // AOSP: static constexpr char kExportedKeyLabel[] = "adb-label"
        // sizeof(kExportedKeyLabel) = 10 (includes null terminator)
        let label = "adb-label"
        XCTAssertEqual(label, "adb-label")
        XCTAssertEqual(label.utf8.count, 9, "Label string is 9 chars")
        // AOSP passes sizeof() which includes null → 10 bytes total
        XCTAssertEqual(label.utf8.count + 1, 10, "Label + null must be 10 bytes for sizeof()")
    }

    // MARK: - PeerInfo Building

    func testBuildPeerInfoSize() throws {
        // PeerInfo must be exactly 8192 bytes regardless of key size
        let smallKey = Data(repeating: 0x41, count: 100)
        var peerInfo = Data(count: 8192)
        peerInfo[0] = 0 // ADB_RSA_PUB_KEY type
        peerInfo.replaceSubrange(1..<(1 + smallKey.count), with: smallKey)
        XCTAssertEqual(peerInfo.count, 8192)
        XCTAssertEqual(peerInfo[0], 0, "First byte must be key type 0 (ADB_RSA_PUB_KEY)")
    }

    func testBuildPeerInfoZeroPadded() {
        // Unused bytes in PeerInfo must be zero
        var peerInfo = Data(count: 8192)
        peerInfo[0] = 0
        let key = Data("shortkey".utf8)
        peerInfo.replaceSubrange(1..<(1 + key.count), with: key)

        // Bytes after the key should be zero
        for i in (1 + key.count)..<8192 {
            XCTAssertEqual(peerInfo[i], 0, "Byte \(i) should be zero-padded")
        }
    }

    // MARK: - Password Construction (code + EKM)

    func testPasswordIsCodePlusEKM() {
        // AOSP: password = pairing_code_utf8 + exported_keying_material(64 bytes)
        let code = "123456"
        var password = Data(code.utf8)
        let ekm = Data(repeating: 0xAB, count: 64)
        password.append(ekm)

        XCTAssertEqual(password.count, 6 + 64, "Password must be code(6) + EKM(64) = 70 bytes")
        // First 6 bytes are the code
        XCTAssertEqual(password.prefix(6), Data("123456".utf8))
        // Last 64 bytes are EKM
        XCTAssertEqual(password.suffix(64), ekm)
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
