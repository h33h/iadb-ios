import Foundation
import XCTest
import CryptoKit
@testable import iADB

final class SPAKE2Tests: XCTestCase {

    // MARK: - SPAKE2Client Tests

    func testSPAKE2ClientGeneratesMessage() throws {
        let client = try SPAKE2Client(password: Data("123456".utf8))
        XCTAssertEqual(client.outgoingMessage.count, 32, "SPAKE2 message should be 32 bytes")
    }

    func testSPAKE2ClientMessageNotIdentity() throws {
        let client = try SPAKE2Client(password: Data("123456".utf8))
        let point = EdPoint.decode([UInt8](client.outgoingMessage))
        XCTAssertNotNil(point, "SPAKE2 message should be a valid point")
        XCTAssertFalse(point!.isIdentity, "SPAKE2 message should not be identity")
    }

    func testSPAKE2ClientDifferentPasswordsDifferentMessages() throws {
        let client1 = try SPAKE2Client(password: Data("123456".utf8))
        let client2 = try SPAKE2Client(password: Data("654321".utf8))
        // Messages should differ (both random + different passwords)
        XCTAssertNotEqual(client1.outgoingMessage, client2.outgoingMessage)
    }

    func testSPAKE2ClientRejectsWrongLengthMessage() throws {
        let client = try SPAKE2Client(password: Data("123456".utf8))
        XCTAssertThrowsError(try client.processServerMessage(Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try client.processServerMessage(Data(repeating: 0, count: 33)))
    }

    func testSPAKE2ClientRejectsInvalidPoint() throws {
        let client = try SPAKE2Client(password: Data("123456".utf8))
        let badPoint = [UInt8](repeating: 0xFF, count: 32)
        XCTAssertThrowsError(try client.processServerMessage(Data(badPoint)))
    }

    func testSPAKE2NameLengths() {
        XCTAssertEqual(SPAKE2Client.clientName.count, 16, "client name should be 16 bytes")
        XCTAssertEqual(SPAKE2Client.serverName.count, 16, "server name should be 16 bytes")
        // Verify null terminators
        XCTAssertEqual(SPAKE2Client.clientName.last, 0)
        XCTAssertEqual(SPAKE2Client.serverName.last, 0)
    }

    // MARK: - PairingAuthEncryptor Tests

    func testEncryptDecryptRoundtrip() throws {
        let keyMaterial = Data(SHA256.hash(data: Data("test key".utf8)))
        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        let plaintext = Data("Hello, ADB pairing!".utf8)
        let encrypted = try encryptor.encrypt(plaintext)

        // Counter-based nonce: output is ciphertext + tag(16), no nonce prefix
        XCTAssertEqual(encrypted.count, plaintext.count + 16)

        let decrypted = try encryptor.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecryptLargePayload() throws {
        let keyMaterial = Data(SHA256.hash(data: Data("test key 2".utf8)))
        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        // Simulate PeerInfo-sized payload (8192 bytes)
        var peerInfo = Data(count: 8192)
        peerInfo[0] = 0 // type
        let keyString = Data("testPublicKey base64data==".utf8)
        peerInfo.replaceSubrange(1..<(1 + keyString.count), with: keyString)

        let encrypted = try encryptor.encrypt(peerInfo)
        XCTAssertEqual(encrypted.count, 8192 + 16)

        let decrypted = try encryptor.decrypt(encrypted)
        XCTAssertEqual(decrypted, peerInfo)
    }

    func testEncryptDecryptMultipleMessages() throws {
        // Verify counter-based nonces work across multiple encrypt/decrypt calls
        let keyMaterial = Data(SHA256.hash(data: Data("counter test".utf8)))
        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        let msg1 = Data("first message".utf8)
        let msg2 = Data("second message".utf8)

        let enc1 = try encryptor.encrypt(msg1)
        let enc2 = try encryptor.encrypt(msg2)

        // Different messages should produce different ciphertext (different counters)
        XCTAssertNotEqual(enc1, enc2)

        let dec1 = try encryptor.decrypt(enc1)
        let dec2 = try encryptor.decrypt(enc2)
        XCTAssertEqual(dec1, msg1)
        XCTAssertEqual(dec2, msg2)
    }

    func testDecryptWrongKeyFails() throws {
        let keyMaterial1 = Data(SHA256.hash(data: Data("key 1".utf8)))
        let keyMaterial2 = Data(SHA256.hash(data: Data("key 2".utf8)))
        let enc1 = PairingAuthEncryptor(keyMaterial: keyMaterial1)
        let enc2 = PairingAuthEncryptor(keyMaterial: keyMaterial2)

        let plaintext = Data("secret data".utf8)
        let encrypted = try enc1.encrypt(plaintext)

        XCTAssertThrowsError(try enc2.decrypt(encrypted))
    }

    func testDecryptTooShortDataFails() throws {
        let keyMaterial = Data(SHA256.hash(data: Data("test".utf8)))
        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        XCTAssertThrowsError(try encryptor.decrypt(Data(repeating: 0, count: 10)))
    }

    // MARK: - Scalar Reduction Tests

    func testReduceModLSmallValue() {
        // A small LE value should remain unchanged
        var input = [UInt8](repeating: 0, count: 64)
        input[0] = 42 // little-endian: value = 42
        let result = SPAKE2Client.reduceModL(input)
        XCTAssertEqual(result[0], 42)
        for i in 1..<32 {
            XCTAssertEqual(result[i], 0, "byte \(i)")
        }
    }

    func testReduceModLGroupOrder() {
        // l itself should reduce to 0
        // l in little-endian (first 32 bytes):
        let lLE: [UInt8] = [
            0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
            0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10
        ]
        var input = [UInt8](repeating: 0, count: 64)
        for i in 0..<32 {
            input[i] = lLE[i]
        }
        let result = SPAKE2Client.reduceModL(input)
        XCTAssertEqual(result, [UInt8](repeating: 0, count: 32), "l mod l should be 0")
    }
}
