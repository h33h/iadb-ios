import Foundation
import CryptoKit

/// SPAKE2 client (alice role) compatible with BoringSSL's implementation.
/// Used for ADB wireless debugging pairing (Android 11+).
struct SPAKE2Client {
    private let passwordHash: [UInt8]  // 64-byte SHA-512 of raw password (for transcript)
    private let x: [UInt8]             // private scalar (reduced mod l, then left_shift_3)
    private let wScalar: [UInt8]       // password scalar = SHA-512(password) reduced mod l
    let outgoingMessage: Data          // T = x·B + w·M, 32 bytes

    // Names: 16 bytes each (15 chars + implicit null terminator)
    // Matches AOSP: static const uint8_t kClientName[] = "adb pair client";
    // sizeof(kClientName) = 16
    static let clientName: Data = {
        var d = Data("adb pair client".utf8)
        d.append(0)
        return d // 16 bytes
    }()
    static let serverName: Data = {
        var d = Data("adb pair server".utf8)
        d.append(0)
        return d // 16 bytes
    }()

    /// Initialize SPAKE2 client with the pairing code as password.
    init(password: Data) throws {
        // Compute and store password hash (needed in transcript)
        let hash = SHA512.hash(data: password)
        self.passwordHash = [UInt8](hash)

        // Password scalar: SHA-512(password) reduced mod l
        // BoringSSL: x25519_sc_reduce treats bytes as little-endian
        self.wScalar = Self.reduceModL(passwordHash)

        // Generate random private scalar x
        var randomBytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, 64, &randomBytes) == errSecSuccess else {
            throw SPAKE2Error.randomGenerationFailed
        }
        var xScalar = Self.reduceModL(randomBytes)
        // BoringSSL applies left_shift_3 to the private scalar (cofactor clearing)
        Self.leftShift3(&xScalar)
        self.x = xScalar

        // Compute T = x·B + w·M
        let xB = EdPoint.B.scalarMult(x)
        let wM = EdPoint.M.scalarMult(wScalar)
        let pointT = xB.add(wM)
        self.outgoingMessage = Data(pointT.encode())
    }

    /// Process the server's SPAKE2 message and return key material (64-byte SHA-512 of transcript).
    func processServerMessage(_ serverMsg: Data) throws -> Data {
        guard serverMsg.count == 32 else {
            throw SPAKE2Error.invalidMessage("Server message must be 32 bytes")
        }

        guard let pointS = EdPoint.decode([UInt8](serverMsg)) else {
            throw SPAKE2Error.invalidMessage("Failed to decode server point")
        }

        // Compute K = x · (S - w·N)
        let wN = EdPoint.N.scalarMult(wScalar)
        let sMinusWN = pointS.add(wN.negate())
        let pointK = sMinusWN.scalarMult(x)

        guard !pointK.isIdentity else {
            throw SPAKE2Error.invalidMessage("Shared secret is identity point")
        }

        let kEncoded = pointK.encode()

        // Build transcript using SHA-512, matching BoringSSL's format:
        // For alice: update(my_name) || update(their_name) || update(my_msg) || update(their_msg) || update(K) || update(password_hash)
        // Each field is: len(8 LE) || data
        // Both sides produce canonical order: alice_name, bob_name, alice_msg, bob_msg, K, password_hash
        var sha = SHA512()

        // Alice's name (client) = our name
        updateWithLengthPrefix(&sha, Self.clientName)
        // Bob's name (server) = their name
        updateWithLengthPrefix(&sha, Self.serverName)
        // Alice's message (T) = our message
        updateWithLengthPrefix(&sha, outgoingMessage)
        // Bob's message (S) = their message
        updateWithLengthPrefix(&sha, serverMsg)
        // Shared secret K
        updateWithLengthPrefix(&sha, Data(kEncoded))
        // Password hash (full 64-byte SHA-512 of raw password)
        updateWithLengthPrefix(&sha, Data(passwordHash))

        let digest = sha.finalize()
        return Data(digest) // 64 bytes
    }

    /// Update SHA-512 with length-prefixed data (8-byte LE length + data).
    /// Matches BoringSSL's update_with_length_prefix.
    private func updateWithLengthPrefix<H: HashFunction>(_ hasher: inout H, _ data: Data) {
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    /// Multiply a 32-byte LE scalar by 8 (left shift by 3 bits).
    /// BoringSSL applies this to the private scalar for cofactor clearing.
    private static func leftShift3(_ scalar: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<scalar.count {
            let newCarry = scalar[i] >> 5
            scalar[i] = (scalar[i] << 3) | carry
            carry = newCarry
        }
    }

    // MARK: - Scalar mod l reduction

    /// Reduce a 64-byte little-endian value modulo the group order l.
    /// BoringSSL's x25519_sc_reduce treats SHA-512 output as little-endian.
    /// Returns 32 bytes little-endian.
    static func reduceModL(_ input: [UInt8]) -> [UInt8] {
        var leBytes = [UInt8](repeating: 0, count: 64)
        for i in 0..<min(input.count, 64) {
            leBytes[i] = input[i]
        }

        // Convert to 8 UInt64 limbs, little-endian order
        var limbs = [UInt64](repeating: 0, count: 8)
        for i in 0..<8 {
            var w: UInt64 = 0
            for j in 0..<8 {
                w |= UInt64(leBytes[i * 8 + j]) << (j * 8)
            }
            limbs[i] = w
        }

        // l as 4 UInt64 limbs (little-endian)
        let l: [UInt64] = [
            0x5812631a5cf5d3ed,
            0x14def9dea2f79cd6,
            0x0000000000000000,
            0x1000000000000000
        ]

        return divModL(limbs: limbs, l: l)
    }

    /// Reduce an 8-limb (512-bit) number modulo l (253-bit), return 32 LE bytes.
    private static func divModL(limbs: [UInt64], l: [UInt64]) -> [UInt8] {
        var rem = limbs

        var remBits = 0
        for i in stride(from: 7, through: 0, by: -1) {
            if rem[i] != 0 {
                remBits = i * 64 + 64 - rem[i].leadingZeroBitCount
                break
            }
        }

        let lBits = 253

        if remBits <= lBits {
            if !isLess(rem, l, count: 8) {
                subtractInPlace(&rem, l, count: 8)
            }
        } else {
            for shift in stride(from: remBits - lBits, through: 0, by: -1) {
                let shifted = shiftLeft(l, by: shift, count: 8)
                if !isLess(rem, shifted, count: 8) {
                    subtractInPlace(&rem, shifted, count: 8)
                }
            }
        }

        var result = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            var w = rem[i]
            for j in 0..<8 {
                result[i * 8 + j] = UInt8(truncatingIfNeeded: w)
                w >>= 8
            }
        }
        return result
    }

    private static func isLess(_ a: [UInt64], _ b: [UInt64], count: Int) -> Bool {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return true }
            if av > bv { return false }
        }
        return false
    }

    private static func subtractInPlace(_ a: inout [UInt64], _ b: [UInt64], count: Int) {
        var borrow: UInt64 = 0
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : UInt64(0)
            let (temp, borrow1) = av.subtractingReportingOverflow(bi)
            let (result, borrow2) = temp.subtractingReportingOverflow(borrow)
            a[i] = result
            borrow = (borrow1 ? 1 : 0) &+ (borrow2 ? 1 : 0)
        }
    }

    private static func shiftLeft(_ a: [UInt64], by shift: Int, count: Int) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: count)
        let wordShift = shift / 64
        let bitShift = shift % 64

        for i in 0..<count {
            let srcIdx = i - wordShift
            if srcIdx >= 0 && srcIdx < a.count {
                result[i] |= a[srcIdx] << bitShift
            }
            if bitShift > 0 {
                let srcIdx2 = srcIdx - 1
                if srcIdx2 >= 0 && srcIdx2 < a.count {
                    result[i] |= a[srcIdx2] >> (64 - bitShift)
                }
            }
        }
        return result
    }

    enum SPAKE2Error: LocalizedError {
        case randomGenerationFailed
        case invalidMessage(String)

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed: return "Failed to generate random bytes"
            case .invalidMessage(let m): return "SPAKE2 error: \(m)"
            }
        }
    }
}
