import Foundation

/// Point on the Ed25519 curve: -x² + y² = 1 + d·x²·y²
/// Uses extended twisted Edwards coordinates (X, Y, Z, T) where x=X/Z, y=Y/Z, T=X·Y/Z.
struct EdPoint {
    var X: FieldElement
    var Y: FieldElement
    var Z: FieldElement
    var T: FieldElement

    /// The identity (neutral) point.
    static let identity = EdPoint(X: .zero, Y: .one, Z: .one, T: .zero)

    // d = -121665/121666 mod p
    // Hex: 52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3
    static let d = FieldElement.decode([
        0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75,
        0xab, 0xd8, 0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00,
        0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
        0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52
    ])

    // 2*d
    static let d2 = EdPoint.d + EdPoint.d

    // Ed25519 base point B
    // y = 4/5 mod p = 46316835694926478169428394003475163141307993866256225615783033890098355573289
    // Compressed: 5866666666666666666666666666666666666666666666666666666666666666
    static let B: EdPoint = {
        let bytes: [UInt8] = [
            0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
        ]
        return decode(bytes)!
    }()

    // SPAKE2 M constant from BoringSSL (kSpakeMSmallPrecomp).
    // BoringSSL stores precomputed tables as (y+x, y-x) field element pairs,
    // NOT compressed Ed25519 points. We reconstruct M from both components.
    static let M: EdPoint? = {
        let ypxBytes: [UInt8] = [
            0xd0, 0x48, 0x03, 0x2c, 0x6e, 0xa0, 0xb6, 0xd6,
            0x97, 0xdd, 0xd0, 0xed, 0x18, 0x18, 0x28, 0xff,
            0x3f, 0xb0, 0xbe, 0xe8, 0x13, 0x68, 0x6c, 0x7f,
            0x53, 0x39, 0x48, 0xaa, 0x12, 0x54, 0x58, 0xc6
        ]
        let ymxBytes: [UInt8] = [
            0x4a, 0xf2, 0x7c, 0xe0, 0xed, 0xf1, 0xa2, 0xe4,
            0x3c, 0xb9, 0xf5, 0x83, 0x44, 0x6a, 0x62, 0x09,
            0xf9, 0x2f, 0xd5, 0x0c, 0x23, 0x00, 0x79, 0x2e,
            0x4d, 0xa4, 0x0f, 0xec, 0xaa, 0xa5, 0x37, 0x02
        ]
        return fromPrecomp(ypxBytes: ypxBytes, ymxBytes: ymxBytes)
    }()

    // SPAKE2 N constant from BoringSSL (kSpakeNSmallPrecomp).
    static let N: EdPoint? = {
        let ypxBytes: [UInt8] = [
            0xd3, 0xbf, 0xb5, 0x18, 0xf4, 0x4f, 0x34, 0x30,
            0xf2, 0x9d, 0x0c, 0x92, 0xaf, 0x50, 0x38, 0x65,
            0xa1, 0xed, 0x32, 0x81, 0xdc, 0x69, 0xb3, 0x5d,
            0xd8, 0x68, 0xba, 0x85, 0xf8, 0x86, 0xab, 0xcd
        ]
        let ymxBytes: [UInt8] = [
            0xc6, 0x0d, 0x46, 0x08, 0x8c, 0x22, 0xa0, 0x40,
            0xa4, 0x59, 0x42, 0x92, 0x54, 0x93, 0x40, 0x3c,
            0x40, 0x86, 0x2f, 0x0e, 0xfa, 0xfb, 0x0d, 0xcc,
            0x0a, 0x0f, 0x91, 0x38, 0x49, 0x69, 0x90, 0x4b
        ]
        return fromPrecomp(ypxBytes: ypxBytes, ymxBytes: ymxBytes)
    }()

    /// Reconstruct an EdPoint from BoringSSL's precomputed (y+x, y-x) pair.
    private static func fromPrecomp(ypxBytes: [UInt8], ymxBytes: [UInt8]) -> EdPoint? {
        let ypx = FieldElement.decode(ypxBytes)
        let ymx = FieldElement.decode(ymxBytes)
        // inv2 = 1/2 mod p = (p+1)/2
        let inv2 = FieldElement(l0: 2, l1: 0, l2: 0, l3: 0, l4: 0).invert()
        let y = (ypx + ymx) * inv2
        let x = (ypx - ymx) * inv2
        let point = EdPoint(X: x, Y: y, Z: .one, T: x * y)
        // Verify the point is on the curve
        let encoded = point.encode()
        guard let decoded = decode(encoded) else { return nil }
        return decoded
    }

    // sqrt(-1) mod p, needed for point decompression
    // = 2^((p-1)/4) mod p
    static let sqrtM1 = FieldElement.decode([
        0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4,
        0x78, 0xe4, 0x2f, 0xad, 0x06, 0x18, 0x43, 0x2f,
        0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
        0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b
    ])

    // MARK: - Point Encoding / Decoding

    /// Decode a 32-byte compressed Ed25519 point.
    /// Returns nil if the point is not on the curve.
    static func decode(_ bytes: [UInt8]) -> EdPoint? {
        guard bytes.count == 32 else { return nil }

        // Extract sign of x from high bit of last byte
        let xSign = Int(bytes[31] >> 7)
        var yBytes = bytes
        yBytes[31] &= 0x7F  // clear sign bit

        let y = FieldElement.decode(yBytes)

        // Compute x from curve equation: x² = (y²-1) / (d·y²+1)
        let y2 = y.squared()
        let u = y2 - .one        // y² - 1
        let v = EdPoint.d * y2 + .one  // d·y² + 1
        // Compute candidate: x = u · v³ · (u · v⁷)^((p-5)/8)
        let v3 = v * v.squared()           // v³
        let uv3 = u * v3                   // u·v³
        let v7 = v3 * v3 * v               // v⁷
        let uv7 = u * v7                   // u·v⁷
        var x = uv3 * uv7.pow2523()        // u·v³ · (u·v⁷)^((p-5)/8)

        // Check: x²·v == u ?
        let check = x.squared() * v
        if (check - u).encode() == [UInt8](repeating: 0, count: 32) {
            // x is correct
        } else if (check + u).encode() == [UInt8](repeating: 0, count: 32) {
            // x needs to be multiplied by sqrt(-1)
            x = x * sqrtM1
        } else {
            return nil // not on curve
        }

        // Adjust sign
        if x.isNegative() != (xSign == 1) {
            x = FieldElement.zero - x
        }

        // Handle x == 0 with wrong sign
        if x.encode() == [UInt8](repeating: 0, count: 32) && xSign == 1 {
            return nil
        }

        return EdPoint(X: x, Y: y, Z: .one, T: x * y)
    }

    /// Encode this point to 32 compressed bytes.
    func encode() -> [UInt8] {
        let zInv = Z.invert()
        let xAff = X * zInv
        let yAff = Y * zInv
        var bytes = yAff.encode()
        // Set high bit of last byte to sign of x
        if xAff.isNegative() {
            bytes[31] |= 0x80
        }
        return bytes
    }

    // MARK: - Point Arithmetic

    /// Add two points using the unified addition formula for extended coordinates.
    func add(_ other: EdPoint) -> EdPoint {
        // RFC 8032 / HWCD08 addition formulas
        let a = (Y - X) * (other.Y - other.X)
        let b = (Y + X) * (other.Y + other.X)
        let c = T * EdPoint.d2 * other.T
        let dd = Z * (other.Z + other.Z)
        let e = b - a
        let f = dd - c
        let g = dd + c
        let h = b + a
        return EdPoint(X: e * f, Y: g * h, Z: f * g, T: e * h)
    }

    /// Double this point (dbl-2008-hwcd for a=-1).
    func doubled() -> EdPoint {
        // A = X², B = Y², C = 2·Z²
        // D = -A (since a=-1), E = (X+Y)²-A-B
        // G = D+B, F = G-C, H = D-B
        let aa = X.squared()
        let bb = Y.squared()
        let cc = Z.squared() + Z.squared()
        let dNeg = FieldElement.zero - aa          // D = -A
        let ePart = (X + Y).squared() - aa - bb   // E
        let gPart = dNeg + bb                      // G = D + B
        let fPart = gPart - cc                     // F = G - C
        let hPart = dNeg - bb                      // H = D - B
        return EdPoint(X: ePart * fPart, Y: gPart * hPart, Z: fPart * gPart, T: ePart * hPart)
    }

    /// Negate this point (-P).
    func negate() -> EdPoint {
        EdPoint(X: FieldElement.zero - X, Y: Y, Z: Z, T: FieldElement.zero - T)
    }

    /// Scalar multiplication: compute scalar * self.
    /// Scalar is a 32-byte little-endian integer.
    func scalarMult(_ scalar: [UInt8]) -> EdPoint {
        var result = EdPoint.identity
        var temp = self

        for byte in scalar {
            for bit in 0..<8 {
                if (byte >> bit) & 1 == 1 {
                    result = result.add(temp)
                }
                temp = temp.doubled()
            }
        }
        return result
    }

    /// Check if this is the identity point.
    var isIdentity: Bool {
        let xBytes = X.encode()
        let yBytes = Y.encode()
        let zBytes = Z.encode()
        let xZero = xBytes == [UInt8](repeating: 0, count: 32)
        let yEqZ = yBytes == zBytes
        return xZero && yEqZ
    }
}
