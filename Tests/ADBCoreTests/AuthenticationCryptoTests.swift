import Foundation
import Security
import CryptoKit
import Testing
@testable import ADBCore

@Suite("RSA-аутентификация")
struct AuthenticationCryptoTests {
    @Test("ADB-токен подписывается как готовый SHA-1 digest")
    func tokenSignatureVerifiesWithoutDoubleHashing() throws {
        let privateKey = try makeEphemeralRSAKey()
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let token = Data((0..<20).map(UInt8.init))

        let signature = try ADBCrypto.sign(token: token, using: privateKey)

        #expect(signature.count == 256)
        var error: Unmanaged<CFError>?
        #expect(SecKeyVerifySignature(
            publicKey,
            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            signature as CFData,
            &error
        ))
    }

    @Test("Открытый ключ ADB содержит корректный RSA-заголовок и exponent")
    func androidPublicKeyUsesExpectedBinaryFormat() throws {
        let privateKey = try makeEphemeralRSAKey()
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))

        let encoded = try ADBCrypto.androidPublicKey(for: publicKey)
        let text = try #require(String(data: encoded, encoding: .utf8))
        let base64 = try #require(text.split(separator: " ").first)
        let bytes = try #require(Data(base64Encoded: String(base64)))

        #expect(text.hasSuffix(" iADB@iOS\0"))
        #expect(bytes.count == 524)
        #expect(readUInt32(bytes, offset: 0) == 64)
        #expect(readUInt32(bytes, offset: 520) == 65_537)
        #expect(readUInt32(bytes, offset: 8) &* readUInt32(bytes, offset: 4) == UInt32.max)
    }

    /// Эталон вычислен отдельно: n0inv = −n⁻¹ по модулю 2³², RR = 2⁴⁰⁹⁶ по модулю n.
    @Test("Формат ADB-ключа совпадает с независимым RSA-вектором")
    func androidPublicKeyMatchesReferenceVector() throws {
        let encodedDER = "MIIBCgKCAQEAxvC13A3brB95IA9rRIBQ8l+rF03HZtkU6rtExOrt44Zt9WcYnaZYGuGRpQiBNqHx/NgFUws1Ov/1vDojtKLGM5X4KgNzvsiZ1Ke/y4VJC1LeqfAZURojP9XhpW6jGrQg/cRDVm0ennzugDmdbdcYMJGo0hYQPDAS6atjihdAaxgHCGm+x625X9pbZV6sSvSBJGLjaYE557Wpnd3MmAgYN3ONv0OU9eQmaNB1wHAtrWOKFL9kbyMRolrI1z6Pjbv6KMKe9V9m07Oj6MbwY89lVA2HgdXhEgfgaERHHB4EbGHkZjbL17sWJFrjhYLgiV6WaBXZQlDfB+3RPTPofKAI5QIDAQAB"
        let der = try #require(Data(base64Encoded: encodedDER))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2_048,
        ]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error))

        let encoded = try ADBCrypto.androidPublicKey(for: key)
        let text = try #require(String(data: encoded, encoding: .utf8))
        let base64 = try #require(text.split(separator: " ").first)
        let wire = try #require(Data(base64Encoded: String(base64)))
        let digest = SHA256.hash(data: wire).map { String(format: "%02x", $0) }.joined()

        #expect(digest == "d9b43fa7ea41690655ee4e9c5a5fae29ca8a52abe7896a1c523225c8e439d194")
    }

    @Test("Открытый ключ другого алгоритма не принимается как RSA")
    func nonRSAKeyIsRejected() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))

        do {
            _ = try ADBCrypto.androidPublicKey(for: publicKey)
            Issue.record("EC-ключ принят как открытый ключ ADB")
        } catch ADBError.cryptoError {
        }
    }

    @Test("Самоподписанный ADB-сертификат корректен и имеет CN adb")
    func selfSignedCertificateParses() throws {
        let privateKey = try makeEphemeralRSAKey()
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))

        let encoded = try ADBCrypto.generateSelfSignedCert(
            privateKey: privateKey,
            publicKey: publicKey
        )
        let certificate = try #require(SecCertificateCreateWithData(nil, encoded as CFData))

        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "adb")
    }

    private func makeEphemeralRSAKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
        ]
        var error: Unmanaged<CFError>?
        return try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}
