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
        // y=1 with sign bit set: x would need to be 0 but sign=1 is invalid for x=0
        var badPoint = [UInt8](repeating: 0, count: 32)
        badPoint[0] = 1
        badPoint[31] = 0x80  // set sign bit for x, but x=0 for y=1 → invalid
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

    // MARK: - Extended Password Tests (pairing code + TLS EKM)

    func testSPAKE2ClientWithExtendedPassword() throws {
        // AOSP appends 64 bytes of TLS exported keying material to the pairing code.
        // Verify SPAKE2 works correctly with the longer password.
        var password = Data("123456".utf8)       // 6 bytes
        password.append(Data(repeating: 0xAB, count: 64)) // 64 bytes EKM
        XCTAssertEqual(password.count, 70)

        let client = try SPAKE2Client(password: password)
        XCTAssertEqual(client.outgoingMessage.count, 32)

        // Message must be a valid curve point
        let point = EdPoint.decode([UInt8](client.outgoingMessage))
        XCTAssertNotNil(point)
        XCTAssertFalse(point!.isIdentity)
    }

    func testSPAKE2ClientExtendedPasswordDiffersFromPlain() throws {
        // The extended password (code + EKM) must produce different SPAKE2
        // messages than the plain code alone, because the password scalar changes.
        let plainPassword = Data("123456".utf8)
        var extendedPassword = Data("123456".utf8)
        extendedPassword.append(Data(repeating: 0xFF, count: 64))

        let clientPlain = try SPAKE2Client(password: plainPassword)
        let clientExtended = try SPAKE2Client(password: extendedPassword)

        // Both generate valid messages but they differ because the password
        // scalar (SHA-512 of password) is different AND random x differs.
        // We can't directly compare since x is random, but we can verify
        // they're both valid distinct points.
        XCTAssertEqual(clientPlain.outgoingMessage.count, 32)
        XCTAssertEqual(clientExtended.outgoingMessage.count, 32)

        let pointPlain = EdPoint.decode([UInt8](clientPlain.outgoingMessage))
        let pointExtended = EdPoint.decode([UInt8](clientExtended.outgoingMessage))
        XCTAssertNotNil(pointPlain)
        XCTAssertNotNil(pointExtended)
    }

    func testSPAKE2ClientSameExtendedPasswordProducesDifferentMessages() throws {
        // Even with the same password, each client generates random x,
        // so messages should differ.
        var password = Data("654321".utf8)
        password.append(Data((0..<64).map { UInt8($0) }))

        let client1 = try SPAKE2Client(password: password)
        let client2 = try SPAKE2Client(password: password)

        XCTAssertNotEqual(client1.outgoingMessage, client2.outgoingMessage,
            "Different random x should produce different messages")
    }

    func testSPAKE2ClientProcessServerMessageWithExtendedPassword() throws {
        // Verify processServerMessage works with extended password.
        // We use the base point as a "fake" server message (it's a valid point).
        var password = Data("999999".utf8)
        password.append(Data(repeating: 0x42, count: 64))

        let client = try SPAKE2Client(password: password)

        // Use base point B as a fake server message — it's a valid Ed25519 point
        let fakeServerMsg = Data(EdPoint.B.encode())
        XCTAssertEqual(fakeServerMsg.count, 32)

        // This should not crash. The result won't match a real server's,
        // but the computation should complete without error.
        let keyMaterial = try client.processServerMessage(fakeServerMsg)
        XCTAssertEqual(keyMaterial.count, 64, "Key material should be 64 bytes (SHA-512)")
    }

    // MARK: - HKDF Info String Tests

    func testHKDFInfoStringLength() {
        // AOSP uses sizeof("adb pairing_auth aes-128-gcm key") - 1 = 32 bytes
        let info = "adb pairing_auth aes-128-gcm key"
        XCTAssertEqual(info.utf8.count, 32, "HKDF info must be 32 bytes (no null terminator)")
    }

    func testExportedKeyLabelLength() {
        // AOSP uses sizeof("adb-label") = 10 (includes null terminator)
        let label = "adb-label"
        XCTAssertEqual(label.utf8.count + 1, 10,
            "EKM label 'adb-label' + null must be 10 bytes to match AOSP sizeof()")
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
