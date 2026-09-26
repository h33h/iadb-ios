import Foundation
import Testing
@testable import ADBCore

@Suite("Кривая Ed25519")
struct CurveCompatibilityTests {
    private let order: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58,
        0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    @Test("Базовая точка имеет стандартное сжатое представление")
    func basePointMatchesReferenceEncoding() {
        #expect(EdPoint.B.encode() == [0x58] + [UInt8](repeating: 0x66, count: 31))
    }

    @Test("Порядок базовой точки равен порядку подгруппы")
    func groupOrderAnnihilatesBasePoint() {
        #expect(EdPoint.B.scalarMult(order).isIdentity)
    }
}
