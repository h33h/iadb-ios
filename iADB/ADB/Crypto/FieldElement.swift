import Foundation

/// Element of the finite field GF(2^255 - 19).
/// Represented as 5 limbs in radix 2^51.
struct FieldElement {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64
    var l3: UInt64
    var l4: UInt64

    static let zero = FieldElement(l0: 0, l1: 0, l2: 0, l3: 0, l4: 0)
    static let one  = FieldElement(l0: 1, l1: 0, l2: 0, l3: 0, l4: 0)

    static let mask51: UInt64 = (1 << 51) - 1

    // MARK: - Encoding / Decoding

    /// Decode 32 little-endian bytes into a field element.
    static func decode(_ bytes: [UInt8]) -> FieldElement {
        precondition(bytes.count == 32)

        let l0 = loadLE64(bytes, 0) & mask51
        let l1 = (loadLE64(bytes, 6) >> 3) & mask51
        let l2 = (loadLE64(bytes, 12) >> 6) & mask51
        let l3 = (loadLE64(bytes, 19) >> 1) & mask51
        let l4 = (loadLE64(bytes, 24) >> 12) & mask51

        return FieldElement(l0: l0, l1: l1, l2: l2, l3: l3, l4: l4)
    }

    /// Load up to 8 bytes as a little-endian UInt64.
    private static func loadLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        let end = min(offset + 8, bytes.count)
        for i in offset..<end {
            v |= UInt64(bytes[i]) << (8 * (i - offset))
        }
        return v
    }

    /// Encode this field element to 32 little-endian bytes (fully reduced).
    func encode() -> [UInt8] {
        let h = fullyReduce()

        // Pack 5 limbs (each ≤ 51 bits, total 255 bits) into 32 bytes LE
        // Bit layout: h0[0..50] h1[51..101] h2[102..152] h3[153..203] h4[204..254]
        var s = [UInt8](repeating: 0, count: 32)

        // h0 occupies bits 0-50 → bytes 0-6 (bits 0-55, only 51 used)
        storeBits(&s, offset: 0, value: h.0, bits: 51)
        // h1 occupies bits 51-101
        storeBits(&s, offset: 51, value: h.1, bits: 51)
        // h2 occupies bits 102-152
        storeBits(&s, offset: 102, value: h.2, bits: 51)
        // h3 occupies bits 153-203
        storeBits(&s, offset: 153, value: h.3, bits: 51)
        // h4 occupies bits 204-254
        storeBits(&s, offset: 204, value: h.4, bits: 51)

        return s
    }

    /// Store `bits` bits of `value` into byte array `s` starting at bit position `offset`.
    private func storeBits(_ s: inout [UInt8], offset: Int, value: UInt64, bits: Int) {
        var remaining = bits
        var val = value
        var bitPos = offset
        while remaining > 0 {
            let byteIdx = bitPos / 8
            let bitIdx = bitPos % 8
            guard byteIdx < s.count else { break }
            let space = 8 - bitIdx
            let toWrite = min(remaining, space)
            let mask = UInt8((1 << toWrite) - 1)
            s[byteIdx] |= UInt8(truncatingIfNeeded: val & UInt64(mask)) << bitIdx
            val >>= toWrite
            bitPos += toWrite
            remaining -= toWrite
        }
    }

    /// Fully reduce mod p, return 5 limbs each < 2^51.
    private func fullyReduce() -> (UInt64, UInt64, UInt64, UInt64, UInt64) {
        var h0 = l0, h1 = l1, h2 = l2, h3 = l3, h4 = l4

        // Carry propagation
        var c: UInt64
        c = h0 >> 51; h1 &+= c; h0 &= Self.mask51
        c = h1 >> 51; h2 &+= c; h1 &= Self.mask51
        c = h2 >> 51; h3 &+= c; h2 &= Self.mask51
        c = h3 >> 51; h4 &+= c; h3 &= Self.mask51
        c = h4 >> 51; h0 &+= c &* 19; h4 &= Self.mask51
        c = h0 >> 51; h1 &+= c; h0 &= Self.mask51

        // Compute q = floor((h + 19) / 2^255) to determine if we need to subtract p
        var q = (19 &+ h0) >> 51
        q = (q &+ h1) >> 51
        q = (q &+ h2) >> 51
        q = (q &+ h3) >> 51
        q = (q &+ h4) >> 51  // q is 0 or 1

        h0 &+= 19 &* q
        c = h0 >> 51; h0 &= Self.mask51
        h1 &+= c; c = h1 >> 51; h1 &= Self.mask51
        h2 &+= c; c = h2 >> 51; h2 &= Self.mask51
        h3 &+= c; c = h3 >> 51; h3 &= Self.mask51
        h4 &+= c; h4 &= Self.mask51

        return (h0, h1, h2, h3, h4)
    }

    // MARK: - Arithmetic

    /// Carry-propagate to keep limbs roughly in range.
    func reduced() -> FieldElement {
        var h0 = l0, h1 = l1, h2 = l2, h3 = l3, h4 = l4
        var c: UInt64
        c = h0 >> 51; h1 &+= c; h0 &= Self.mask51
        c = h1 >> 51; h2 &+= c; h1 &= Self.mask51
        c = h2 >> 51; h3 &+= c; h2 &= Self.mask51
        c = h3 >> 51; h4 &+= c; h3 &= Self.mask51
        c = h4 >> 51; h0 &+= c &* 19; h4 &= Self.mask51
        c = h0 >> 51; h1 &+= c; h0 &= Self.mask51
        return FieldElement(l0: h0, l1: h1, l2: h2, l3: h3, l4: h4)
    }

    static func + (a: FieldElement, b: FieldElement) -> FieldElement {
        FieldElement(
            l0: a.l0 &+ b.l0,
            l1: a.l1 &+ b.l1,
            l2: a.l2 &+ b.l2,
            l3: a.l3 &+ b.l3,
            l4: a.l4 &+ b.l4
        )
    }

    static func - (a: FieldElement, b: FieldElement) -> FieldElement {
        // p in limb form: l0 = 2^51-19, l1=l2=l3=l4 = 2^51-1
        // Add 2p to avoid underflow
        let p2_0: UInt64 = 0xFFFFFFFFFFFDA   // 2*(2^51 - 19) = 2^52 - 38
        let p2_mid: UInt64 = 0xFFFFFFFFFFFFE  // 2*(2^51 - 1) = 2^52 - 2
        let p2_4: UInt64 = 0xFFFFFFFFFFFFE    // 2*(2^51 - 1) = 2^52 - 2
        return FieldElement(
            l0: (a.l0 &+ p2_0) &- b.l0,
            l1: (a.l1 &+ p2_mid) &- b.l1,
            l2: (a.l2 &+ p2_mid) &- b.l2,
            l3: (a.l3 &+ p2_mid) &- b.l3,
            l4: (a.l4 &+ p2_4) &- b.l4
        ).reduced()
    }

    /// Multiply two field elements.
    static func * (a: FieldElement, b: FieldElement) -> FieldElement {
        let a0 = a.l0, a1 = a.l1, a2 = a.l2, a3 = a.l3, a4 = a.l4
        let b0 = b.l0, b1 = b.l1, b2 = b.l2, b3 = b.l3, b4 = b.l4

        let b1_19 = 19 &* b1
        let b2_19 = 19 &* b2
        let b3_19 = 19 &* b3
        let b4_19 = 19 &* b4

        var r0 = mul128(a0, b0)
        r0 = add128(r0, mul128(a1, b4_19))
        r0 = add128(r0, mul128(a2, b3_19))
        r0 = add128(r0, mul128(a3, b2_19))
        r0 = add128(r0, mul128(a4, b1_19))

        var r1 = mul128(a0, b1)
        r1 = add128(r1, mul128(a1, b0))
        r1 = add128(r1, mul128(a2, b4_19))
        r1 = add128(r1, mul128(a3, b3_19))
        r1 = add128(r1, mul128(a4, b2_19))

        var r2 = mul128(a0, b2)
        r2 = add128(r2, mul128(a1, b1))
        r2 = add128(r2, mul128(a2, b0))
        r2 = add128(r2, mul128(a3, b4_19))
        r2 = add128(r2, mul128(a4, b3_19))

        var r3 = mul128(a0, b3)
        r3 = add128(r3, mul128(a1, b2))
        r3 = add128(r3, mul128(a2, b1))
        r3 = add128(r3, mul128(a3, b0))
        r3 = add128(r3, mul128(a4, b4_19))

        var r4 = mul128(a0, b4)
        r4 = add128(r4, mul128(a1, b3))
        r4 = add128(r4, mul128(a2, b2))
        r4 = add128(r4, mul128(a3, b1))
        r4 = add128(r4, mul128(a4, b0))

        return carryPropagate(r0, r1, r2, r3, r4)
    }

    /// Squaring (optimized via symmetry).
    func squared() -> FieldElement {
        let a0 = l0, a1 = l1, a2 = l2, a3 = l3, a4 = l4
        let d0 = 2 &* a0
        let d1 = 2 &* a1
        let d2x19 = 2 &* 19 &* a2
        let a419 = 19 &* a4
        let a319 = 19 &* a3

        var r0 = Self.mul128(a0, a0)
        r0 = Self.add128(r0, Self.mul128(d1, a419))
        r0 = Self.add128(r0, Self.mul128(d2x19, a3))

        var r1 = Self.mul128(d0, a1)
        r1 = Self.add128(r1, Self.mul128(2 &* a2, a419))
        r1 = Self.add128(r1, Self.mul128(a319, a3))

        var r2 = Self.mul128(d0, a2)
        r2 = Self.add128(r2, Self.mul128(a1, a1))
        r2 = Self.add128(r2, Self.mul128(2 &* a3, a419))

        var r3 = Self.mul128(d0, a3)
        r3 = Self.add128(r3, Self.mul128(d1, a2))
        r3 = Self.add128(r3, Self.mul128(a419, a4))

        var r4 = Self.mul128(d0, a4)
        r4 = Self.add128(r4, Self.mul128(d1, a3))
        r4 = Self.add128(r4, Self.mul128(a2, a2))

        return Self.carryPropagate(r0, r1, r2, r3, r4)
    }

    /// Compute self^(p-2) for modular inverse (Fermat's little theorem).
    func invert() -> FieldElement {
        var t0, t1, t2, t3: FieldElement

        t0 = self.squared()                                 // 2
        t1 = t0.squared().squared()                          // 8
        t1 = self * t1                                       // 9
        t0 = t0 * t1                                         // 11
        t2 = t0.squared()                                    // 22
        t1 = t1 * t2                                         // 31 = 2^5 - 1

        t2 = t1
        for _ in 0..<5 { t2 = t2.squared() }                // 2^10 - 2^5
        t1 = t2 * t1                                         // 2^10 - 1

        t2 = t1
        for _ in 0..<10 { t2 = t2.squared() }               // 2^20 - 2^10
        t2 = t2 * t1                                         // 2^20 - 1

        t3 = t2
        for _ in 0..<20 { t3 = t3.squared() }               // 2^40 - 2^20
        t2 = t3 * t2                                         // 2^40 - 1

        for _ in 0..<10 { t2 = t2.squared() }               // 2^50 - 2^10
        t1 = t2 * t1                                         // 2^50 - 1

        t2 = t1
        for _ in 0..<50 { t2 = t2.squared() }               // 2^100 - 2^50
        t2 = t2 * t1                                         // 2^100 - 1

        t3 = t2
        for _ in 0..<100 { t3 = t3.squared() }              // 2^200 - 2^100
        t2 = t3 * t2                                         // 2^200 - 1

        for _ in 0..<50 { t2 = t2.squared() }               // 2^250 - 2^50
        t1 = t2 * t1                                         // 2^250 - 1

        t1 = t1.squared().squared()                          // 2^252 - 4
        t1 = t1.squared()                                    // 2^253 - 8
        t1 = t1.squared()                                    // 2^254 - 16
        t1 = t1.squared()                                    // 2^255 - 32
        return t1 * t0                                       // 2^255 - 21 = p - 2
    }

    /// Compute self^((p-5)/8) = self^(2^252-3) for square root.
    func pow2523() -> FieldElement {
        var t0, t1, t2: FieldElement

        t0 = self.squared()                                  // 2
        t1 = t0.squared().squared()                          // 8
        t1 = self * t1                                       // 9
        t0 = t0 * t1                                         // 11
        t0 = t0.squared()                                    // 22
        t0 = t1 * t0                                         // 31 = 2^5 - 1

        t1 = t0
        for _ in 0..<5 { t1 = t1.squared() }                // 2^10 - 2^5
        t0 = t1 * t0                                         // 2^10 - 1

        t1 = t0
        for _ in 0..<10 { t1 = t1.squared() }               // 2^20 - 2^10
        t1 = t1 * t0                                         // 2^20 - 1

        t2 = t1
        for _ in 0..<20 { t2 = t2.squared() }               // 2^40 - 2^20
        t1 = t2 * t1                                         // 2^40 - 1

        for _ in 0..<10 { t1 = t1.squared() }               // 2^50 - 2^10
        t0 = t1 * t0                                         // 2^50 - 1

        t1 = t0
        for _ in 0..<50 { t1 = t1.squared() }               // 2^100 - 2^50
        t1 = t1 * t0                                         // 2^100 - 1

        t2 = t1
        for _ in 0..<100 { t2 = t2.squared() }              // 2^200 - 2^100
        t1 = t2 * t1                                         // 2^200 - 1

        for _ in 0..<50 { t1 = t1.squared() }               // 2^250 - 2^50
        t0 = t1 * t0                                         // 2^250 - 1

        t0 = t0.squared().squared()                          // 2^252 - 4
        return t0 * self                                     // 2^252 - 3
    }

    /// Check if the least significant bit is 1 ("negative" by Ed25519 convention).
    func isNegative() -> Bool {
        let bytes = encode()
        return (bytes[0] & 1) != 0
    }

    /// Conditional negate: return -self if condition is true.
    func conditionalNegate(_ condition: Bool) -> FieldElement {
        condition ? (FieldElement.zero - self) : self
    }

    // MARK: - 128-bit helpers

    static func mul128(_ a: UInt64, _ b: UInt64) -> (hi: UInt64, lo: UInt64) {
        let r = a.multipliedFullWidth(by: b)
        return (r.high, r.low)
    }

    static func add128(_ a: (hi: UInt64, lo: UInt64), _ b: (hi: UInt64, lo: UInt64)) -> (hi: UInt64, lo: UInt64) {
        let (lo, overflow) = a.lo.addingReportingOverflow(b.lo)
        return (a.hi &+ b.hi &+ (overflow ? 1 : 0), lo)
    }

    /// Carry-propagate 128-bit accumulators into 5 limbs.
    static func carryPropagate(
        _ r0: (hi: UInt64, lo: UInt64),
        _ r1: (hi: UInt64, lo: UInt64),
        _ r2: (hi: UInt64, lo: UInt64),
        _ r3: (hi: UInt64, lo: UInt64),
        _ r4: (hi: UInt64, lo: UInt64)
    ) -> FieldElement {
        func shr51(_ v: (hi: UInt64, lo: UInt64)) -> UInt64 {
            (v.lo >> 51) | (v.hi << 13)
        }

        let c0 = shr51(r0)
        let h0 = r0.lo & mask51
        let s1 = add128(r1, (0, c0))
        let c1 = shr51(s1)
        let h1 = s1.lo & mask51
        let s2 = add128(r2, (0, c1))
        let c2 = shr51(s2)
        let h2 = s2.lo & mask51
        let s3 = add128(r3, (0, c2))
        let c3 = shr51(s3)
        let h3 = s3.lo & mask51
        let s4 = add128(r4, (0, c3))
        let c4 = shr51(s4)
        let h4 = s4.lo & mask51

        let h0f = h0 &+ c4 &* 19
        let c0f = h0f >> 51
        return FieldElement(l0: h0f & mask51, l1: h1 &+ c0f, l2: h2, l3: h3, l4: h4)
    }
}
