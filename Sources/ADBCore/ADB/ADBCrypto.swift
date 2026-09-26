import Foundation
import Security
import CryptoKit
import os

/// Управляет ключом идентификации ADB в Keychain и TLS-сертификатом.
public final class ADBCrypto: ADBSigningIdentity, @unchecked Sendable {
    private static let keyTag = "com.iadb.adbkey"
    private static let keySizeInBits = 2048
    private static let rsaNumWords = 64

    static let log = Logger(subsystem: "com.iadb.adbcore", category: "adb")

    private let privateKey: SecKey
    let publicKey: SecKey
    let keyOrigin: String

    public init() throws {
        if let existingKey = ADBCrypto.loadPrivateKey() {
            self.privateKey = existingKey
            guard let pubKey = SecKeyCopyPublicKey(existingKey) else {
                throw ADBError.cryptoError("Failed to extract public key")
            }
            self.publicKey = pubKey
            self.keyOrigin = "keychain"
        } else {
            let (priv, pub, origin) = try ADBCrypto.generateKeyPair()
            self.privateKey = priv
            self.publicKey = pub
            self.keyOrigin = origin
        }
        ADBCrypto.log.info("ADBCrypto init: origin=\(self.keyOrigin, privacy: .public) pubFingerprint=\(self.publicKeyFingerprint(), privacy: .private(mask: .hash))")
    }

    /// Возвращает SHA-256 отпечаток открытого ключа.
    public func publicKeyFingerprint() -> String {
        Self.fingerprint(for: publicKey) ?? "<no-pubkey>"
    }

    public static func hasStoredIdentity() -> Bool {
        storedIdentityFingerprint() != nil
    }

    public static func storedIdentityFingerprint() -> String? {
        if let privateKey = loadPrivateKey(),
           let publicKey = SecKeyCopyPublicKey(privateKey) {
            return fingerprint(for: publicKey)
        }
        return nil
    }

    private static func fingerprint(for publicKey: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func generateKeyPair() throws -> (SecKey, SecKey, String) {

        let persistentAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeInBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(keyTag.utf8)
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        if let privateKey = SecKeyCreateRandomKey(persistentAttributes as CFDictionary, &error) {
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw ADBError.cryptoError("Failed to extract public key")
            }
            return (privateKey, publicKey, "keychain-new")
        }

        let persistErr = error?.takeRetainedValue().localizedDescription ?? "unknown"

        if let privateKey = loadPrivateKey(),
           let publicKey = SecKeyCopyPublicKey(privateKey) {
            return (privateKey, publicKey, "keychain-race")
        }
        throw ADBError.cryptoError(
            "Secure key storage is unavailable: \(persistErr)"
        )
    }

    private static func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            log.error("Keychain returned an invalid RSA private key reference")
            return nil
        }
        return unsafeDowncast(item, to: SecKey.self)
    }

    func sign(token: Data) throws -> Data {
        try Self.sign(token: token, using: privateKey)
    }

    static func sign(token: Data, using privateKey: SecKey) throws -> Data {
        guard token.count == 20 else {
            throw ADBError.cryptoError("ADB authentication token must be a 20-byte SHA-1 digest")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,

            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            &error
        ) else {
            throw ADBError.cryptoError("Signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return signature as Data
    }

    func adbPublicKey() throws -> Data {
        try Self.androidPublicKey(for: publicKey)
    }

    static func androidPublicKey(for publicKey: SecKey) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              keyType == kSecAttrKeyTypeRSA as String,
              SecKeyGetBlockSize(publicKey) == 256 else {
            throw ADBError.cryptoError("ADB requires a 2048-bit RSA public key")
        }
        let (modulus, exponent) = try Self.extractRSAComponents(for: publicKey)
        let androidKey = Self.encodeAndroidRSAPublicKey(modulus: modulus, exponent: exponent)
        let base64Key = androidKey.base64EncodedString()
        let keyString = base64Key + " iADB@iOS\0"
        guard let keyData = keyString.data(using: .utf8) else {
            throw ADBError.cryptoError("Failed to encode public key string")
        }
        return keyData
    }

    @discardableResult
    static func deleteKeys() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyTag.utf8)
        ]
        return SecItemDelete(query as CFDictionary)
    }

    /// Удаляет сохранённый ключ и связанный сертификат ADB.
    public static func deleteStoredIdentity() throws {
        let keyStatus = deleteKeys()
        let acceptedStatuses: Set<OSStatus> = [errSecSuccess, errSecItemNotFound]
        guard acceptedStatuses.contains(keyStatus), !hasStoredIdentity() else {
            throw ADBError.cryptoError(
                "Failed to remove the ADB private key from Keychain (status: \(keyStatus))"
            )
        }

        let certificateStatus = deleteCertificate()
        if !acceptedStatuses.contains(certificateStatus) {
            log.warning("Could not remove stale ADB certificate: \(certificateStatus, privacy: .public)")
        }
    }

    private static func extractRSAComponents(for publicKey: SecKey) throws -> (modulus: [UInt8], exponent: UInt32) {
        var error: Unmanaged<CFError>?
        guard let derData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ADBError.cryptoError("Failed to export key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        let bytes = [UInt8](derData)
        var offset = 0

        offset = Self.skipDERTagAndLength(bytes, offset: offset)

        let modulus = Self.readDERInteger(bytes, offset: &offset)

        let exponent = Self.readDERInteger(bytes, offset: &offset)
        guard modulus.count == 256, !exponent.isEmpty, exponent.count <= 4 else {
            throw ADBError.cryptoError("Invalid RSA public key encoding")
        }

        var expValue: UInt32 = 0
        for byte in exponent {
            expValue = (expValue << 8) | UInt32(byte)
        }
        guard expValue > 1, expValue & 1 == 1 else {
            throw ADBError.cryptoError("Invalid RSA public exponent")
        }

        return (modulus, expValue)
    }

    private static func skipDERTagAndLength(_ bytes: [UInt8], offset: Int) -> Int {
        guard offset + 1 < bytes.count else { return bytes.count }
        var off = offset + 1
        if bytes[off] & 0x80 != 0 {
            let lenBytes = Int(bytes[off] & 0x7F)
            off += 1 + lenBytes
        } else {
            off += 1
        }
        return min(off, bytes.count)
    }

    private static func readDERInteger(_ bytes: [UInt8], offset: inout Int) -> [UInt8] {
        guard offset < bytes.count, bytes[offset] == 0x02 else { return [] }
        offset += 1
        guard offset < bytes.count else { return [] }

        var length = 0
        if bytes[offset] & 0x80 != 0 {
            let lenBytes = Int(bytes[offset] & 0x7F)
            offset += 1
            guard offset + lenBytes <= bytes.count else { return [] }
            for i in 0..<lenBytes {
                length = (length << 8) | Int(bytes[offset + i])
            }
            offset += lenBytes
        } else {
            length = Int(bytes[offset])
            offset += 1
        }

        guard offset + length <= bytes.count else { return [] }
        var data = Array(bytes[offset..<(offset + length)])
        offset += length

        if data.first == 0 && data.count > 1 {
            data.removeFirst()
        }
        return data
    }

    private static func encodeAndroidRSAPublicKey(modulus: [UInt8], exponent: UInt32) -> Data {
        let numWords = ADBCrypto.rsaNumWords

        let modulusLE = Self.bigEndianBytesToLEWords(modulus, wordCount: numWords)

        let n0inv = Self.computeN0inv(modulusLE[0])

        let rr = Self.computeRR(modulusLE: modulusLE, numWords: numWords)

        var data = Data(capacity: 4 + 4 + numWords * 4 + numWords * 4 + 4)

        Self.appendUInt32LE(&data, UInt32(numWords))
        Self.appendUInt32LE(&data, n0inv)

        for word in modulusLE {
            Self.appendUInt32LE(&data, word)
        }

        for word in rr {
            Self.appendUInt32LE(&data, word)
        }

        Self.appendUInt32LE(&data, exponent)

        return data
    }

    private static func bigEndianBytesToLEWords(_ bytes: [UInt8], wordCount: Int) -> [UInt32] {

        let requiredBytes = wordCount * 4
        var padded = [UInt8](repeating: 0, count: requiredBytes)
        let start = requiredBytes - bytes.count
        if start >= 0 {
            for i in 0..<bytes.count {
                padded[start + i] = bytes[i]
            }
        }

        var words = [UInt32](repeating: 0, count: wordCount)
        for i in 0..<wordCount {
            let byteIdx = requiredBytes - (i + 1) * 4
            words[i] = UInt32(padded[byteIdx]) << 24
                     | UInt32(padded[byteIdx + 1]) << 16
                     | UInt32(padded[byteIdx + 2]) << 8
                     | UInt32(padded[byteIdx + 3])
        }
        return words
    }

    private static func computeN0inv(_ n0: UInt32) -> UInt32 {

        var inv: UInt32 = 1
        var t = n0
        for _ in 0..<31 {
            inv = inv &* t
            t = t &* t
        }
        return 0 &- inv
    }

    private static func computeRR(modulusLE: [UInt32], numWords: Int) -> [UInt32] {

        var rr = [UInt32](repeating: 0, count: numWords)
        rr[0] = 1

        let totalBits = numWords * 32 * 2
        for _ in 0..<totalBits {
            rr = Self.bigNumShiftLeftMod(rr, modulus: modulusLE, numWords: numWords)
        }

        return rr
    }

    private static func bigNumShiftLeftMod(_ a: [UInt32], modulus: [UInt32], numWords: Int) -> [UInt32] {

        var result = [UInt32](repeating: 0, count: numWords)
        var carry: UInt32 = 0
        for i in 0..<numWords {
            let newCarry = a[i] >> 31
            result[i] = (a[i] << 1) | carry
            carry = newCarry
        }

        if carry != 0 || Self.bigNumCompare(result, modulus, numWords: numWords) >= 0 {
            result = Self.bigNumSubtract(result, modulus, numWords: numWords)
        }

        return result
    }

    private static func bigNumCompare(_ a: [UInt32], _ b: [UInt32], numWords: Int) -> Int {
        for i in stride(from: numWords - 1, through: 0, by: -1) {
            if a[i] > b[i] { return 1 }
            if a[i] < b[i] { return -1 }
        }
        return 0
    }

    private static func bigNumSubtract(_ a: [UInt32], _ b: [UInt32], numWords: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: numWords)
        var borrow: UInt64 = 0
        for i in 0..<numWords {
            let diff = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            result[i] = UInt32(truncatingIfNeeded: diff)
            borrow = (diff >> 63) & 1
        }
        return result
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static let certLabel = "com.iadb.adbkey-cert"

    func tlsIdentity() throws -> SecIdentity {

        let deleteStatus = Self.deleteCertificate()
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw ADBError.cryptoError("Failed to replace TLS certificate in Keychain: \(deleteStatus)")
        }

        let certDER = try Self.generateSelfSignedCert(privateKey: privateKey, publicKey: publicKey)
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw ADBError.cryptoError("Failed to parse generated certificate")
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: Self.certLabel
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ADBError.cryptoError("Failed to add certificate to Keychain: \(status)")
        }

        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw ADBError.cryptoError("Failed to create TLS identity from the ADB key and certificate")
        }
        return identity
    }

    @discardableResult
    static func deleteCertificate() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func generateSelfSignedCert(privateKey: SecKey, publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let pkcs1DER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ADBError.cryptoError("Failed to export public key")
        }

        let oidSHA256RSA: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]
        let oidRSA: [UInt8]       = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        let oidCN: [UInt8]        = [0x06, 0x03, 0x55, 0x04, 0x03]
        let oidBasicConstraints: [UInt8] = [0x06, 0x03, 0x55, 0x1d, 0x13]
        let oidKeyUsage: [UInt8]         = [0x06, 0x03, 0x55, 0x1d, 0x0f]
        let oidExtKeyUsage: [UInt8]      = [0x06, 0x03, 0x55, 0x1d, 0x25]
        let oidClientAuth: [UInt8]       = [0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]
        let oidServerAuth: [UInt8]       = [0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
        let derNull: [UInt8]      = [0x05, 0x00]
        let derTrue: [UInt8]      = [0x01, 0x01, 0xFF]

        let sigAlgo = Self.derTag(0x30, Data(oidSHA256RSA + derNull))

        let cnAttr = Self.derTag(0x30, Data(oidCN) + Self.derTag(0x0C, Data("adb".utf8)))
        let name = Self.derTag(0x30, Self.derTag(0x31, cnAttr))

        let now = Date()
        guard let future = Calendar(identifier: .gregorian).date(
            byAdding: .year,
            value: 10,
            to: now
        ) else {
            throw ADBError.cryptoError("Failed to calculate certificate validity")
        }
        let validity = Self.derTag(0x30, Self.derCertificateTime(now) + Self.derCertificateTime(future))

        let spkiAlgo = Self.derTag(0x30, Data(oidRSA + derNull))
        let spki = Self.derTag(0x30, spkiAlgo + Self.derBitString(pkcs1DER))

        let serial = Self.derTag(0x02, Data([0x01]))

        let version = Self.derTag(0xA0, Self.derTag(0x02, Data([0x02])))

        let bcValue = Self.derTag(0x30, Data())
        let bcExt = Self.derTag(0x30, Data(oidBasicConstraints) + Data(derTrue) + Self.derTag(0x04, bcValue))

        let kuValue = Self.derTag(0x03, Data([0x02, 0xA0]))
        let kuExt = Self.derTag(0x30, Data(oidKeyUsage) + Data(derTrue) + Self.derTag(0x04, kuValue))

        let ekuValue = Self.derTag(0x30, Data(oidClientAuth) + Data(oidServerAuth))
        let ekuExt = Self.derTag(0x30, Data(oidExtKeyUsage) + Self.derTag(0x04, ekuValue))

        let extensionsSeq = Self.derTag(0x30, bcExt + kuExt + ekuExt)
        let extensions = Self.derTag(0xA3, extensionsSeq)

        let tbs = Self.derTag(0x30, version + serial + sigAlgo + name + validity + name + spki + extensions)

        error = nil
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw ADBError.cryptoError("Failed to sign certificate: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        return Self.derTag(0x30, tbs + sigAlgo + Self.derBitString(signature))
    }

    private static func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: Self.derLength(content.count))
        result.append(content)
        return result
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length <= 0xFF {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }

    private static func derBitString(_ content: Data) -> Data {

        var inner = Data([0x00])
        inner.append(content)
        return Self.derTag(0x03, inner)
    }

    private static func derUTCTime(_ date: Date) -> Data {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyMMddHHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let str = fmt.string(from: date) + "Z"
        return Self.derTag(0x17, Data(str.utf8))
    }

    static func derCertificateTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: date)
        guard year < 1950 || year >= 2050 else { return Self.derUTCTime(date) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return Self.derTag(0x18, Data(formatter.string(from: date).utf8))
    }
}
