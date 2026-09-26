import Foundation
import CryptoKit

struct SPAKE2Client {
    private let passwordHash: [UInt8]
    private let x: [UInt8]
    private let wScalar: [UInt8]
    let outgoingMessage: Data

    static let clientName: Data = {
        var d = Data("adb pair client".utf8)
        d.append(0)
        return d
    }()
    static let serverName: Data = {
        var d = Data("adb pair server".utf8)
        d.append(0)
        return d
    }()

    init(password: Data) throws {

        let hash = SHA512.hash(data: password)
        self.passwordHash = [UInt8](hash)

        self.wScalar = Self.cofactorSafePasswordScalar(Self.reduceModL(passwordHash))

        var randomBytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, 64, &randomBytes) == errSecSuccess else {
            throw SPAKE2Error.randomGenerationFailed
        }
        var xScalar = Self.reduceModL(randomBytes)

        Self.leftShift3(&xScalar)
        self.x = xScalar

        guard let M = EdPoint.M else {
            throw SPAKE2Error.invalidMessage("Failed to decode SPAKE2 M constant")
        }
        let xB = EdPoint.B.scalarMult(x)
        let wM = M.scalarMult(wScalar)
        let pointT = xB.add(wM)
        self.outgoingMessage = Data(pointT.encode())
    }

    func processServerMessage(_ serverMsg: Data) throws -> Data {
        guard serverMsg.count == 32 else {
            throw SPAKE2Error.invalidMessage("Server message must be 32 bytes")
        }

        guard let pointS = EdPoint.decode([UInt8](serverMsg)) else {
            throw SPAKE2Error.invalidMessage("Failed to decode server point")
        }

        guard let N = EdPoint.N else {
            throw SPAKE2Error.invalidMessage("Failed to decode SPAKE2 N constant")
        }
        let wN = N.scalarMult(wScalar)
        let sMinusWN = pointS.add(wN.negate())
        let pointK = sMinusWN.scalarMult(x)

        guard !pointK.isIdentity else {
            throw SPAKE2Error.invalidMessage("Shared secret is identity point")
        }

        let kEncoded = pointK.encode()

        var sha = SHA512()

        updateWithLengthPrefix(&sha, Self.clientName)

        updateWithLengthPrefix(&sha, Self.serverName)

        updateWithLengthPrefix(&sha, outgoingMessage)

        updateWithLengthPrefix(&sha, serverMsg)

        updateWithLengthPrefix(&sha, Data(kEncoded))

        updateWithLengthPrefix(&sha, Data(passwordHash))

        let digest = sha.finalize()
        return Data(digest)
    }

    private func updateWithLengthPrefix<H: HashFunction>(_ hasher: inout H, _ data: Data) {
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func leftShift3(_ scalar: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<scalar.count {
            let newCarry = scalar[i] >> 5
            scalar[i] = (scalar[i] << 3) | carry
            carry = newCarry
        }
    }

    /// Добавляет кратные порядку подгруппы, чтобы скаляр маски делился на кофактор восемь.
    private static func cofactorSafePasswordScalar(_ reduced: [UInt8]) -> [UInt8] {
        var scalar = reduced
        var order: [UInt8] = [
            0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
            0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        ]

        for bit in 0..<3 {
            let mask = UInt8(0) &- ((scalar[0] >> bit) & 1)
            var carry: UInt16 = 0
            for index in scalar.indices {
                let sum = UInt16(scalar[index]) + UInt16(order[index] & mask) + carry
                scalar[index] = UInt8(truncatingIfNeeded: sum)
                carry = sum >> 8
            }

            carry = 0
            for index in order.indices {
                let doubled = UInt16(order[index]) * 2 + carry
                order[index] = UInt8(truncatingIfNeeded: doubled)
                carry = doubled >> 8
            }
        }
        return scalar
    }

    static func reduceModL(_ input: [UInt8]) -> [UInt8] {
        var leBytes = [UInt8](repeating: 0, count: 64)
        for i in 0..<min(input.count, 64) {
            leBytes[i] = input[i]
        }

        var limbs = [UInt64](repeating: 0, count: 8)
        for i in 0..<8 {
            var w: UInt64 = 0
            for j in 0..<8 {
                w |= UInt64(leBytes[i * 8 + j]) << (j * 8)
            }
            limbs[i] = w
        }

        let l: [UInt64] = [
            0x5812631a5cf5d3ed,
            0x14def9dea2f79cd6,
            0x0000000000000000,
            0x1000000000000000
        ]

        return divModL(limbs: limbs, l: l)
    }

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
            case .randomGenerationFailed: return String(localized: "Failed to generate random bytes")
            case .invalidMessage(let m): return String(localized: "SPAKE2 error: \(m)")
            }
        }
    }
}
