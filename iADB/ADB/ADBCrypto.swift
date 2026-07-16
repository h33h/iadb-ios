import Foundation
import Security
import CryptoKit
import os

/// Handles RSA key generation and signing for ADB authentication
final class ADBCrypto {
    private static let keyTag = "com.iadb.adbkey"
    private static let resetMarkerService = "com.iadb.adbidentity-reset"
    private static let resetMarkerAccount = "pending"
    private static let keySizeInBits = 2048
    private static let rsaNumWords = 64 // 2048 / 32

    #if DEBUG
    private static let debugEphemeralLock = NSLock()
    private static var debugEphemeralKeyPair: (privateKey: SecKey, publicKey: SecKey)?
    #endif

    static let log = Logger(subsystem: "com.iadb.app", category: "adb")

    private let privateKey: SecKey
    let publicKey: SecKey
    private(set) var keyOrigin: String = "unknown"

    init() throws {
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

    /// SHA256 fingerprint публичного ключа (PKCS#1 DER) — для сверки между pairing и connect.
    func publicKeyFingerprint() -> String {
        Self.fingerprint(for: publicKey) ?? "<no-pubkey>"
    }

    static func hasStoredIdentity() -> Bool {
        storedIdentityFingerprint() != nil
    }

    static func storedIdentityFingerprint() -> String? {
        if let privateKey = loadPrivateKey(),
           let publicKey = SecKeyCopyPublicKey(privateKey) {
            return fingerprint(for: publicKey)
        }
        #if DEBUG
        debugEphemeralLock.lock()
        defer { debugEphemeralLock.unlock() }
        return debugEphemeralKeyPair.flatMap { fingerprint(for: $0.publicKey) }
        #else
        return nil
        #endif
    }

    private static func fingerprint(for publicKey: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Key Management

    private static func generateKeyPair() throws -> (SecKey, SecKey, String) {
        // Try persistent key first (stored in keychain)
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
        // Another caller may have created the key between our initial lookup and
        // SecKeyCreateRandomKey. Reuse it instead of rotating the ADB identity.
        if let privateKey = loadPrivateKey(),
           let publicKey = SecKeyCopyPublicKey(privateKey) {
            return (privateKey, publicKey, "keychain-race")
        }

        #if DEBUG
        // XCTest/simulator processes may run without Keychain entitlements. A
        // single process-wide key keeps pairing and connect on the same identity.
        // Release builds must never pair with an identity that cannot persist.
        debugEphemeralLock.lock()
        defer { debugEphemeralLock.unlock() }
        if let pair = debugEphemeralKeyPair {
            return (pair.privateKey, pair.publicKey, "debug-ephemeral-shared")
        }
        let ephemeralAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeInBits
        ]

        error = nil
        guard let privateKey = SecKeyCreateRandomKey(ephemeralAttributes as CFDictionary, &error) else {
            throw ADBError.cryptoError("Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ADBError.cryptoError("Failed to extract public key")
        }
        debugEphemeralKeyPair = (privateKey, publicKey)
        log.warning("Keychain unavailable in DEBUG: \(persistErr, privacy: .private(mask: .hash))")
        return (privateKey, publicKey, "debug-ephemeral-shared")
        #else
        throw ADBError.cryptoError(
            "Secure key storage is unavailable. Reinstall the signed app or verify Keychain access, then try again. (\(persistErr))"
        )
        #endif
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
        return unsafeBitCast(item, to: SecKey.self)
    }

    // MARK: - ADB Auth Operations

    /// Sign an ADB auth token with our private key (SHA1 + PKCS1 v1.5)
    func sign(token: Data) throws -> Data {
        guard token.count == 20 else {
            throw ADBError.cryptoError("ADB authentication token must be a 20-byte SHA-1 digest")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            // adbd supplies an already-computed 20-byte SHA-1 token. Using the
            // message variant would hash it a second time and produce a signature
            // that real Android devices reject.
            .rsaSignatureDigestPKCS1v15SHA1,
            token as CFData,
            &error
        ) else {
            throw ADBError.cryptoError("Signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return signature as Data
    }

    /// Get the public key in Android ADB format:
    /// base64(AndroidRSAPublicKey struct) + " iADB@iOS\0"
    ///
    /// Android expects a specific binary struct, NOT standard PKCS#1 DER.
    /// See: https://android.googlesource.com/platform/system/core/+/refs/heads/main/libcrypto_utils/android_pubkey.cpp
    func adbPublicKey() throws -> Data {
        let (modulus, exponent) = try extractRSAComponents()
        let androidKey = encodeAndroidRSAPublicKey(modulus: modulus, exponent: exponent)
        let base64Key = androidKey.base64EncodedString()
        let keyString = base64Key + " iADB@iOS\0"
        guard let keyData = keyString.data(using: .utf8) else {
            throw ADBError.cryptoError("Failed to encode public key string")
        }
        return keyData
    }

    /// Delete stored keys (for key rotation)
    @discardableResult
    static func deleteKeys() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyTag.utf8)
        ]
        let status = SecItemDelete(query as CFDictionary)
        #if DEBUG
        debugEphemeralLock.lock()
        debugEphemeralKeyPair = nil
        debugEphemeralLock.unlock()
        #endif
        return status
    }

    static func deleteStoredIdentity() throws {
        let keyStatus = deleteKeys()
        let acceptedStatuses: Set<OSStatus> = [errSecSuccess, errSecItemNotFound]
        guard acceptedStatuses.contains(keyStatus), !hasStoredIdentity() else {
            throw ADBError.cryptoError(
                "Failed to remove the ADB private key from Keychain (status: \(keyStatus))"
            )
        }

        // The private key is the trust-bearing identity. A stale public
        // certificate cannot authenticate on its own, so its cleanup is best
        // effort and must not turn a successful security reset into a failure.
        let certificateStatus = deleteCertificate()
        if !acceptedStatuses.contains(certificateStatus) {
            log.warning("Could not remove stale ADB certificate: \(certificateStatus, privacy: .public)")
        }
    }

    static func markIdentityResetPending() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resetMarkerService,
            kSecAttrAccount as String: resetMarkerAccount,
            kSecValueData as String: Data([1])
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ADBError.cryptoError("Failed to record the pending ADB identity reset (status: \(status))")
        }
    }

    static func isIdentityResetPending() throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resetMarkerService,
            kSecAttrAccount as String: resetMarkerAccount,
            kSecReturnData as String: false
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw ADBError.cryptoError("Failed to read the pending ADB identity reset (status: \(status))")
        }
    }

    static func clearIdentityResetPending() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resetMarkerService,
            kSecAttrAccount as String: resetMarkerAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ADBError.cryptoError("Failed to finish the ADB identity reset (status: \(status))")
        }
    }

    // MARK: - Android RSA Public Key Encoding

    /// Extract modulus and exponent from the SecKey (PKCS#1 DER format)
    private func extractRSAComponents() throws -> (modulus: [UInt8], exponent: UInt32) {
        var error: Unmanaged<CFError>?
        guard let derData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ADBError.cryptoError("Failed to export key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        // PKCS#1 RSAPublicKey DER:
        // SEQUENCE { INTEGER (modulus), INTEGER (exponent) }
        let bytes = [UInt8](derData)
        var offset = 0

        // Skip outer SEQUENCE tag + length
        offset = skipDERTagAndLength(bytes, offset: offset)

        // Read modulus INTEGER
        let modulus = readDERInteger(bytes, offset: &offset)

        // Read exponent INTEGER
        let exponent = readDERInteger(bytes, offset: &offset)

        let expValue: UInt32
        if exponent.count <= 4 {
            var val: UInt32 = 0
            for b in exponent {
                val = (val << 8) | UInt32(b)
            }
            expValue = val
        } else {
            expValue = 65537
        }

        return (modulus, expValue)
    }

    private func skipDERTagAndLength(_ bytes: [UInt8], offset: Int) -> Int {
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

    private func readDERInteger(_ bytes: [UInt8], offset: inout Int) -> [UInt8] {
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

    /// Encode public key in Android's RSAPublicKey struct format:
    /// ```
    /// struct RSAPublicKey {
    ///     uint32_t len;           // Number of uint32_t in modulus (64 for RSA-2048)
    ///     uint32_t n0inv;         // -1 / n[0] mod 2^32
    ///     uint32_t n[len];        // Modulus as little-endian uint32_t array
    ///     uint32_t rr[len];       // R^2 mod n as little-endian uint32_t array
    ///     int32_t  exponent;      // Public exponent (65537)
    /// };
    /// ```
    private func encodeAndroidRSAPublicKey(modulus: [UInt8], exponent: UInt32) -> Data {
        let numWords = ADBCrypto.rsaNumWords // 64

        // Convert modulus bytes (big-endian) to little-endian uint32 array
        let modulusLE = bigEndianBytesToLEWords(modulus, wordCount: numWords)

        // Compute n0inv = -1/n[0] mod 2^32
        let n0inv = computeN0inv(modulusLE[0])

        // Compute R^2 mod n (R = 2^(numWords*32))
        let rr = computeRR(modulusLE: modulusLE, numWords: numWords)

        // Build the struct
        var data = Data(capacity: 4 + 4 + numWords * 4 + numWords * 4 + 4)

        appendUInt32LE(&data, UInt32(numWords))
        appendUInt32LE(&data, n0inv)

        for word in modulusLE {
            appendUInt32LE(&data, word)
        }

        for word in rr {
            appendUInt32LE(&data, word)
        }

        appendUInt32LE(&data, exponent)

        return data
    }

    /// Convert big-endian byte array to little-endian uint32 array
    private func bigEndianBytesToLEWords(_ bytes: [UInt8], wordCount: Int) -> [UInt32] {
        // Pad to required size
        let requiredBytes = wordCount * 4
        var padded = [UInt8](repeating: 0, count: requiredBytes)
        let start = requiredBytes - bytes.count
        if start >= 0 {
            for i in 0..<bytes.count {
                padded[start + i] = bytes[i]
            }
        }

        // Convert to little-endian uint32 array
        // padded is big-endian bytes, we need LE word array
        // Word 0 = least significant 4 bytes
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

    /// Compute n0inv = -1/n[0] mod 2^32
    /// Using the extended Euclidean algorithm approach
    private func computeN0inv(_ n0: UInt32) -> UInt32 {
        // We need: n0inv * n0 ≡ -1 (mod 2^32)
        // Equivalent: n0inv = (2^32 - modInverse(n0, 2^32)) mod 2^32
        // Use iterative method: start with inv = 1, refine
        var inv: UInt32 = 1
        var t = n0
        for _ in 0..<31 {
            inv = inv &* t
            t = t &* t
        }
        return 0 &- inv  // -inv mod 2^32
    }

    /// Compute R^2 mod n where R = 2^(numWords * 32)
    /// Using repeated doubling and modular reduction
    private func computeRR(modulusLE: [UInt32], numWords: Int) -> [UInt32] {
        // Start with RR = 1
        var rr = [UInt32](repeating: 0, count: numWords)
        rr[0] = 1

        // Double RR (numWords * 32 * 2) times, each time computing mod n
        let totalBits = numWords * 32 * 2
        for _ in 0..<totalBits {
            rr = bigNumShiftLeftMod(rr, modulus: modulusLE, numWords: numWords)
        }

        return rr
    }

    /// Left shift a big number by 1 bit, then reduce mod n
    private func bigNumShiftLeftMod(_ a: [UInt32], modulus: [UInt32], numWords: Int) -> [UInt32] {
        // Shift left by 1
        var result = [UInt32](repeating: 0, count: numWords)
        var carry: UInt32 = 0
        for i in 0..<numWords {
            let newCarry = a[i] >> 31
            result[i] = (a[i] << 1) | carry
            carry = newCarry
        }

        // If result >= modulus, subtract modulus
        if carry != 0 || bigNumCompare(result, modulus, numWords: numWords) >= 0 {
            result = bigNumSubtract(result, modulus, numWords: numWords)
        }

        return result
    }

    /// Compare two big numbers, return -1, 0, or 1
    private func bigNumCompare(_ a: [UInt32], _ b: [UInt32], numWords: Int) -> Int {
        for i in stride(from: numWords - 1, through: 0, by: -1) {
            if a[i] > b[i] { return 1 }
            if a[i] < b[i] { return -1 }
        }
        return 0
    }

    /// Subtract b from a (assumes a >= b)
    private func bigNumSubtract(_ a: [UInt32], _ b: [UInt32], numWords: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: numWords)
        var borrow: UInt64 = 0
        for i in 0..<numWords {
            let diff = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            result[i] = UInt32(truncatingIfNeeded: diff)
            borrow = (diff >> 63) & 1  // borrow if underflow
        }
        return result
    }

    private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    // MARK: - TLS Identity for Pairing (mTLS)

    private static let certLabel = "com.iadb.adbkey-cert"

    /// Create a SecIdentity for TLS mutual authentication.
    /// AOSP pairing server requires client certificate (SSL_VERIFY_FAIL_IF_NO_PEER_CERT).
    /// Generates a self-signed X.509 cert from our RSA key and stores it in the Keychain.
    func tlsIdentity() throws -> SecIdentity {
        // Remove stale cert so it always matches current key
        let deleteStatus = Self.deleteCertificate()
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw ADBError.cryptoError("Failed to replace TLS certificate in Keychain: \(deleteStatus)")
        }

        let certDER = try generateSelfSignedCert()
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

        // Keychain automatically matches cert with private key via public key hash
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: Data(Self.keyTag.utf8),
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let idStatus = SecItemCopyMatching(identityQuery as CFDictionary, &item)
        guard idStatus == errSecSuccess else {
            throw ADBError.cryptoError("Failed to create TLS identity: \(idStatus)")
        }
        guard let item, CFGetTypeID(item) == SecIdentityGetTypeID() else {
            throw ADBError.cryptoError("Keychain returned an invalid TLS identity")
        }
        return unsafeBitCast(item, to: SecIdentity.self)
    }

    @discardableResult
    static func deleteCertificate() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel
        ]
        return SecItemDelete(query as CFDictionary)
    }

    /// Build a self-signed X.509 v3 certificate in DER format.
    /// Соответствует тому, что генерит AOSP `adb` для wireless debugging:
    /// v3, CN=adb, EKU clientAuth+serverAuth, basicConstraints CA:false.
    func generateSelfSignedCert() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let pkcs1DER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ADBError.cryptoError("Failed to export public key")
        }

        // OIDs
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

        let sigAlgo = derTag(0x30, Data(oidSHA256RSA + derNull))

        // Issuer = Subject: CN=adb
        let cnAttr = derTag(0x30, Data(oidCN) + derTag(0x0C, Data("adb".utf8)))
        let name = derTag(0x30, derTag(0x31, cnAttr))

        // Validity: now → now + 10 years
        let now = Date()
        guard let future = Calendar(identifier: .gregorian).date(
            byAdding: .year,
            value: 10,
            to: now
        ) else {
            throw ADBError.cryptoError("Failed to calculate certificate validity")
        }
        let validity = derTag(0x30, derUTCTime(now) + derUTCTime(future))

        // SubjectPublicKeyInfo: algorithm + BIT STRING wrapping PKCS#1
        let spkiAlgo = derTag(0x30, Data(oidRSA + derNull))
        let spki = derTag(0x30, spkiAlgo + derBitString(pkcs1DER))

        // Serial number
        let serial = derTag(0x02, Data([0x01]))

        // X.509 v3 marker: [0] EXPLICIT INTEGER 2
        let version = derTag(0xA0, derTag(0x02, Data([0x02])))

        // Extensions
        // basicConstraints: CA=FALSE (critical, пустой SEQUENCE)
        let bcValue = derTag(0x30, Data())
        let bcExt = derTag(0x30, Data(oidBasicConstraints) + Data(derTrue) + derTag(0x04, bcValue))

        // keyUsage: digitalSignature(0) + keyEncipherment(2) (critical)
        // BIT STRING: 1 unused bit, 0b10100000 = 0xA0
        let kuValue = derTag(0x03, Data([0x02, 0xA0]))
        let kuExt = derTag(0x30, Data(oidKeyUsage) + Data(derTrue) + derTag(0x04, kuValue))

        // extKeyUsage: clientAuth + serverAuth
        let ekuValue = derTag(0x30, Data(oidClientAuth) + Data(oidServerAuth))
        let ekuExt = derTag(0x30, Data(oidExtKeyUsage) + derTag(0x04, ekuValue))

        let extensionsSeq = derTag(0x30, bcExt + kuExt + ekuExt)
        let extensions = derTag(0xA3, extensionsSeq)  // [3] EXPLICIT

        // TBSCertificate v3
        let tbs = derTag(0x30, version + serial + sigAlgo + name + validity + name + spki + extensions)

        // Sign TBSCertificate
        error = nil
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw ADBError.cryptoError("Failed to sign certificate: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        // Full Certificate
        return derTag(0x30, tbs + sigAlgo + derBitString(signature))
    }

    // MARK: - DER Encoding Helpers

    func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: derLength(content.count))
        result.append(content)
        return result
    }

    func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length <= 0xFF {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }

    func derBitString(_ content: Data) -> Data {
        // BIT STRING: tag + length + 0x00 (no unused bits) + content
        var inner = Data([0x00])
        inner.append(content)
        return derTag(0x03, inner)
    }

    func derUTCTime(_ date: Date) -> Data {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyMMddHHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let str = fmt.string(from: date) + "Z"
        return derTag(0x17, Data(str.utf8))
    }
}
