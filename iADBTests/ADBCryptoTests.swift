import Foundation
import XCTest
@testable import iADB

final class ADBCryptoTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clean up any existing keys to ensure test isolation
        ADBCrypto.deleteKeys()
    }

    override func tearDown() {
        ADBCrypto.deleteKeys()
        super.tearDown()
    }

    func testKeyGeneration() throws {
        let crypto = try ADBCrypto()
        XCTAssertNotNil(crypto.publicKey)
    }

    func testKeyPersistence() throws {
        // Generate key
        let crypto1 = try ADBCrypto()

        // Load same key
        let crypto2 = try ADBCrypto()

        // Both should have the same public key
        var error1: Unmanaged<CFError>?
        var error2: Unmanaged<CFError>?
        let data1 = SecKeyCopyExternalRepresentation(crypto1.publicKey, &error1) as Data?
        let data2 = SecKeyCopyExternalRepresentation(crypto2.publicKey, &error2) as Data?

        XCTAssertNotNil(data1)
        XCTAssertNotNil(data2)
        XCTAssertEqual(data1, data2)
    }

    func testSignToken() throws {
        let crypto = try ADBCrypto()
        let token = Data((0..<20).map { _ in UInt8.random(in: 0...255) })

        let signature = try crypto.sign(token: token)
        XCTAssertFalse(signature.isEmpty)
        XCTAssertEqual(signature.count, 256) // RSA-2048 signature = 256 bytes
    }

    func testSignDifferentTokensProduceDifferentSignatures() throws {
        let crypto = try ADBCrypto()
        let token1 = Data(repeating: 0xAA, count: 20)
        let token2 = Data(repeating: 0xBB, count: 20)

        let sig1 = try crypto.sign(token: token1)
        let sig2 = try crypto.sign(token: token2)

        XCTAssertNotEqual(sig1, sig2)
    }

    func testADBPublicKeyFormat() throws {
        let crypto = try ADBCrypto()
        let keyData = try crypto.adbPublicKey()

        // Should be valid UTF-8
        let keyString = String(data: keyData, encoding: .utf8)
        XCTAssertNotNil(keyString)

        // Should contain the identifier
        XCTAssertTrue(keyString!.contains("iADB@iOS"))

        // Should end with null terminator
        XCTAssertEqual(keyData.last, 0)

        // Key should be base64 + space + identifier + null
        let parts = keyString!.dropLast().components(separatedBy: " ")
        XCTAssertEqual(parts.count, 2)

        // First part should be valid base64
        let base64Part = parts[0]
        let decoded = Data(base64Encoded: base64Part)
        XCTAssertNotNil(decoded)

        // Decoded Android RSAPublicKey struct:
        // 4 bytes len + 4 bytes n0inv + 64*4 modulus + 64*4 rr + 4 exponent
        // = 4 + 4 + 256 + 256 + 4 = 524 bytes
        XCTAssertEqual(decoded!.count, 524)

        // First 4 bytes should be len = 64 (little-endian)
        let len = decoded!.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(len.littleEndian, 64)

        // Last 4 bytes should be exponent = 65537 (little-endian)
        let expOffset = decoded!.count - 4
        let exp = decoded!.withUnsafeBytes { buf in
            buf.load(fromByteOffset: expOffset, as: UInt32.self)
        }
        XCTAssertEqual(exp.littleEndian, 65537)
    }

    func testDeleteKeys() throws {
        _ = try ADBCrypto()
        ADBCrypto.deleteKeys()

        // After deletion, creating a new instance should generate new keys
        let crypto2 = try ADBCrypto()
        XCTAssertNotNil(crypto2.publicKey)
    }
}
