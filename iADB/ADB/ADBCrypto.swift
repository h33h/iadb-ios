import Foundation
import Security

/// Handles RSA key generation and signing for ADB authentication
final class ADBCrypto {
    private static let keyTag = "com.iadb.adbkey"
    private static let keySizeInBits = 2048
    private static let rsaNumWords = 64 // 2048 / 32

    private let privateKey: SecKey
    let publicKey: SecKey

    init() throws {
        if let existingKey = ADBCrypto.loadPrivateKey() {
            self.privateKey = existingKey
            guard let pubKey = SecKeyCopyPublicKey(existingKey) else {
                throw ADBError.cryptoError("Failed to extract public key")
            }
            self.publicKey = pubKey
        } else {
            let (priv, pub) = try ADBCrypto.generateKeyPair()
            self.privateKey = priv
            self.publicKey = pub
        }
    }

    // MARK: - Key Management

    private static func generateKeyPair() throws -> (SecKey, SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeInBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ADBError.cryptoError("Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ADBError.cryptoError("Failed to extract public key")
        }

        return (privateKey, publicKey)
    }

    private static func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    // MARK: - ADB Auth Operations

    /// Sign an ADB auth token with our private key (SHA1 + PKCS1 v1.5)
    func sign(token: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA1,
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
    static func deleteKeys() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!
        ]
        SecItemDelete(query as CFDictionary)
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
        var off = offset + 1 // skip tag
        if bytes[off] & 0x80 != 0 {
            let lenBytes = Int(bytes[off] & 0x7F)
            off += 1 + lenBytes
        } else {
            off += 1
        }
        return off
    }

    private func readDERInteger(_ bytes: [UInt8], offset: inout Int) -> [UInt8] {
        guard bytes[offset] == 0x02 else { return [] } // INTEGER tag
        offset += 1

        var length = 0
        if bytes[offset] & 0x80 != 0 {
            let lenBytes = Int(bytes[offset] & 0x7F)
            offset += 1
            for i in 0..<lenBytes {
                length = (length << 8) | Int(bytes[offset + i])
            }
            offset += lenBytes
        } else {
            length = Int(bytes[offset])
            offset += 1
        }

        // Skip leading zero byte (sign byte) if present
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
}
