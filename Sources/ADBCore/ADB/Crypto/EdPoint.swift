import Foundation

struct EdPoint {
    var X: FieldElement
    var Y: FieldElement
    var Z: FieldElement
    var T: FieldElement

    static let identity = EdPoint(X: .zero, Y: .one, Z: .one, T: .zero)

    static let d = FieldElement.decode([
        0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75,
        0xab, 0xd8, 0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00,
        0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
        0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52
    ])

    static let d2 = EdPoint.d + EdPoint.d

    static let B: EdPoint = {
        let bytes: [UInt8] = [
            0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
            0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
        ]
        return decode(bytes)!
    }()

    static let M: EdPoint? = {
        let compressed: [UInt8] = [
            0x5a, 0xda, 0x7e, 0x4b, 0xf6, 0xdd, 0xd9, 0xad,
            0xb6, 0x62, 0x6d, 0x32, 0x13, 0x1c, 0x6b, 0x5c,
            0x51, 0xa1, 0xe3, 0x47, 0xa3, 0x47, 0x8f, 0x53,
            0xcf, 0xcf, 0x44, 0x1b, 0x88, 0xee, 0xd1, 0x2e
        ]
        return decode(compressed)
    }()

    static let N: EdPoint? = {
        let compressed: [UInt8] = [
            0x10, 0xe3, 0xdf, 0x0a, 0xe3, 0x7d, 0x8e, 0x7a,
            0x99, 0xb5, 0xfe, 0x74, 0xb4, 0x46, 0x72, 0x10,
            0x3d, 0xbd, 0xdc, 0xbd, 0x06, 0xaf, 0x68, 0x0d,
            0x71, 0x32, 0x9a, 0x11, 0x69, 0x3b, 0xc7, 0x78
        ]
        return decode(compressed)
    }()

    static let sqrtM1 = FieldElement.decode([
        0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4,
        0x78, 0xe4, 0x2f, 0xad, 0x06, 0x18, 0x43, 0x2f,
        0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
        0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b
    ])

    static func decode(_ bytes: [UInt8]) -> EdPoint? {
        guard bytes.count == 32 else { return nil }

        let xSign = Int(bytes[31] >> 7)
        var yBytes = bytes
        yBytes[31] &= 0x7F

        let y = FieldElement.decode(yBytes)

        let y2 = y.squared()
        let u = y2 - .one
        let v = EdPoint.d * y2 + .one

        let v3 = v * v.squared()
        let uv3 = u * v3
        let v7 = v3 * v3 * v
        let uv7 = u * v7
        var x = uv3 * uv7.pow2523()

        let check = x.squared() * v
        if (check - u).encode() == [UInt8](repeating: 0, count: 32) {

        } else if (check + u).encode() == [UInt8](repeating: 0, count: 32) {

            x = x * sqrtM1
        } else {
            return nil
        }

        if x.isNegative() != (xSign == 1) {
            x = FieldElement.zero - x
        }

        if x.encode() == [UInt8](repeating: 0, count: 32) && xSign == 1 {
            return nil
        }

        return EdPoint(X: x, Y: y, Z: .one, T: x * y)
    }

    func encode() -> [UInt8] {
        let zInv = Z.invert()
        let xAff = X * zInv
        let yAff = Y * zInv
        var bytes = yAff.encode()

        if xAff.isNegative() {
            bytes[31] |= 0x80
        }
        return bytes
    }

    func add(_ other: EdPoint) -> EdPoint {

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

    func doubled() -> EdPoint {

        let aa = X.squared()
        let bb = Y.squared()
        let cc = Z.squared() + Z.squared()
        let dNeg = FieldElement.zero - aa
        let ePart = (X + Y).squared() - aa - bb
        let gPart = dNeg + bb
        let fPart = gPart - cc
        let hPart = dNeg - bb
        return EdPoint(X: ePart * fPart, Y: gPart * hPart, Z: fPart * gPart, T: ePart * hPart)
    }

    func negate() -> EdPoint {
        EdPoint(X: FieldElement.zero - X, Y: Y, Z: Z, T: FieldElement.zero - T)
    }

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

    var isIdentity: Bool {
        let xBytes = X.encode()
        let yBytes = Y.encode()
        let zBytes = Z.encode()
        let xZero = xBytes == [UInt8](repeating: 0, count: 32)
        let yEqZ = yBytes == zBytes
        return xZero && yEqZ
    }
}
