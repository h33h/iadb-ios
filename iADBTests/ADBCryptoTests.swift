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
        ADBCrypto.deleteCertificate()
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

        // Both should have the same public key (only when keychain is available)
        var error1: Unmanaged<CFError>?
        var error2: Unmanaged<CFError>?
        let data1 = SecKeyCopyExternalRepresentation(crypto1.publicKey, &error1) as Data?
        let data2 = SecKeyCopyExternalRepresentation(crypto2.publicKey, &error2) as Data?

        XCTAssertNotNil(data1)
        XCTAssertNotNil(data2)

        // In CI without keychain, ephemeral keys are generated each time,
        // so they won't match. Only assert equality if keys can persist.
        if ADBCryptoTests.isKeychainAvailable() {
            XCTAssertEqual(data1, data2)
        }
    }

    /// Check if the keychain is accessible (it's not in CI runners).
    private static func isKeychainAvailable() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.iadb.keychain-test",
            kSecValueData as String: Data([0x42]),
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            SecItemDelete(query as CFDictionary)
            return true
        }
        return addStatus != errSecMissingEntitlement && addStatus != -34018
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

    // MARK: - Self-Signed Certificate Generation

    func testGenerateSelfSignedCertIsValidDER() throws {
        let crypto = try ADBCrypto()
        let certDER = try crypto.generateSelfSignedCert()

        // Must be parseable by SecCertificateCreateWithData
        let cert = SecCertificateCreateWithData(nil, certDER as CFData)
        XCTAssertNotNil(cert, "Generated DER must be a valid X.509 certificate")
    }

    func testGenerateSelfSignedCertStructure() throws {
        let crypto = try ADBCrypto()
        let certDER = try crypto.generateSelfSignedCert()
        let bytes = [UInt8](certDER)

        // Must start with SEQUENCE tag
        XCTAssertEqual(bytes[0], 0x30, "Certificate must be a DER SEQUENCE")

        // Must be non-trivially long (RSA-2048 cert is ~600-900 bytes)
        XCTAssertGreaterThan(certDER.count, 400, "RSA-2048 cert should be >400 bytes")
        XCTAssertLessThan(certDER.count, 2000, "Certificate should not be excessively large")
    }

    func testGenerateSelfSignedCertContainsSubjectCN() throws {
        let crypto = try ADBCrypto()
        let certDER = try crypto.generateSelfSignedCert()

        let cert = SecCertificateCreateWithData(nil, certDER as CFData)!
        let summary = SecCertificateCopySubjectSummary(cert) as String?
        XCTAssertEqual(summary, "adb", "Certificate subject CN should be 'adb'")
    }

    func testGenerateSelfSignedCertDeterministicStructure() throws {
        let crypto = try ADBCrypto()
        let cert1 = try crypto.generateSelfSignedCert()
        let cert2 = try crypto.generateSelfSignedCert()

        // Same key, same subject → same TBS structure, same signature
        // (deterministic signing with PKCS1v15)
        // Note: validity timestamps may differ by a second, so we only check
        // that both are parseable
        XCTAssertNotNil(SecCertificateCreateWithData(nil, cert1 as CFData))
        XCTAssertNotNil(SecCertificateCreateWithData(nil, cert2 as CFData))
    }

    func testTLSIdentityCreation() throws {
        guard ADBCryptoTests.isKeychainAvailable() else {
            // Keychain not available in CI — skip
            return
        }

        let crypto = try ADBCrypto()
        let identity = try crypto.tlsIdentity()

        // Verify the identity contains our key
        var privateKey: SecKey?
        let status = SecIdentityCopyPrivateKey(identity, &privateKey)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(privateKey)

        // Verify the identity contains a certificate
        var cert: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &cert)
        XCTAssertEqual(certStatus, errSecSuccess)
        XCTAssertNotNil(cert)

        // Certificate subject should be CN=adb
        let summary = SecCertificateCopySubjectSummary(cert!) as String?
        XCTAssertEqual(summary, "adb")
    }

    func testTLSIdentityRecreatedAfterKeyRotation() throws {
        guard ADBCryptoTests.isKeychainAvailable() else { return }

        let crypto1 = try ADBCrypto()
        let identity1 = try crypto1.tlsIdentity()

        // Delete keys and regenerate
        ADBCrypto.deleteKeys()
        ADBCrypto.deleteCertificate()

        let crypto2 = try ADBCrypto()
        let identity2 = try crypto2.tlsIdentity()

        // Both should be valid identities
        var cert1: SecCertificate?
        var cert2: SecCertificate?
        SecIdentityCopyCertificate(identity1, &cert1)
        SecIdentityCopyCertificate(identity2, &cert2)
        XCTAssertNotNil(cert1)
        XCTAssertNotNil(cert2)
    }

    // MARK: - DER Encoding Helpers

    func testDERLengthShort() throws {
        let crypto = try ADBCrypto()
        // Lengths < 128 are single byte
        XCTAssertEqual(crypto.derLength(0), [0x00])
        XCTAssertEqual(crypto.derLength(1), [0x01])
        XCTAssertEqual(crypto.derLength(127), [0x7F])
    }

    func testDERLengthMedium() throws {
        let crypto = try ADBCrypto()
        // Lengths 128-255 use 0x81 prefix
        XCTAssertEqual(crypto.derLength(128), [0x81, 0x80])
        XCTAssertEqual(crypto.derLength(255), [0x81, 0xFF])
    }

    func testDERLengthLong() throws {
        let crypto = try ADBCrypto()
        // Lengths 256-65535 use 0x82 prefix
        XCTAssertEqual(crypto.derLength(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(crypto.derLength(1000), [0x82, 0x03, 0xE8])
    }

    func testDERTagSequence() throws {
        let crypto = try ADBCrypto()
        let content = Data([0x01, 0x02, 0x03])
        let result = crypto.derTag(0x30, content)
        // SEQUENCE tag (0x30) + length (3) + content
        XCTAssertEqual([UInt8](result), [0x30, 0x03, 0x01, 0x02, 0x03])
    }

    func testDERBitString() throws {
        let crypto = try ADBCrypto()
        let content = Data([0xAA, 0xBB])
        let result = crypto.derBitString(content)
        // BIT STRING tag (0x03) + length (3) + 0x00 (no unused bits) + content
        XCTAssertEqual([UInt8](result), [0x03, 0x03, 0x00, 0xAA, 0xBB])
    }

    func testDERUTCTime() throws {
        let crypto = try ADBCrypto()
        // Create a known date: 2025-01-15 12:30:45 UTC
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 15
        components.hour = 12
        components.minute = 30
        components.second = 45
        components.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar.current.date(from: components)!

        let result = crypto.derUTCTime(date)
        let bytes = [UInt8](result)
        // UTCTime tag (0x17) + length + "250115123045Z"
        XCTAssertEqual(bytes[0], 0x17) // UTCTime tag
        let timeString = String(data: Data(bytes[2...]), encoding: .utf8)
        XCTAssertEqual(timeString, "250115123045Z")
    }
}
