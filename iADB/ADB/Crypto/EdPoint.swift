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

    // SPAKE2 M: seed = "edwards25519 point generation seed (M)"
    // x = 31406539342727633121250288103050113562375374900226415211311216773867585644232
    // y = 21177308356423958466833845032658859666296341766942662650232962324899758529114
    static let M: EdPoint? = {
        let compressed: [UInt8] = [
            0x5a, 0xda, 0x7e, 0x4b, 0xf6, 0xdd, 0xd9, 0xad,
            0xb6, 0x62, 0x6d, 0x32, 0x13, 0x1c, 0x6b, 0x5c,
            0x51, 0xa1, 0xe3, 0x47, 0xa3, 0x47, 0x8f, 0x53,
            0xcf, 0xcf, 0x44, 0x1b, 0x88, 0xee, 0xd1, 0x2e
        ]
        return decode(compressed)
    }()

    // SPAKE2 N: seed = "edwards25519 point generation seed (N)"
    // x = 49918732221787544735331783592030787422991506689877079631459872391322455579424
    // y = 54629554431565467720832445949441049581317094546788069926228343916274969994000
    static let N: EdPoint? = {
        let compressed: [UInt8] = [
            0x10, 0xe3, 0xdf, 0x0a, 0xe3, 0x7d, 0x8e, 0x7a,
            0x99, 0xb5, 0xfe, 0x74, 0xb4, 0x46, 0x72, 0x10,
            0x3d, 0xbd, 0xdc, 0xbd, 0x06, 0xaf, 0x68, 0x0d,
            0x71, 0x32, 0x9a, 0x11, 0x69, 0x3b, 0xc7, 0x78
        ]
        return decode(compressed)
    }()

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
