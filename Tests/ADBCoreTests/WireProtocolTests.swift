import Foundation
import Testing
@testable import ADBCore

@Suite("Транспортный протокол")
struct WireProtocolTests {
    @Test("CNXN сериализуется в известные байты ADB")
    func connectMessageMatchesWireFixture() {
        let message = ADBMessage(
            command: .connect,
            arg0: 0x0100_0001,
            arg1: 4_096,
            data: Data("abc".utf8)
        )
        let expected: [UInt8] = [
            0x43, 0x4E, 0x58, 0x4E,
            0x01, 0x00, 0x00, 0x01,
            0x00, 0x10, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
            0x26, 0x01, 0x00, 0x00,
            0xBC, 0xB1, 0xA7, 0xB1,
            0x61, 0x62, 0x63,
        ]

        #expect([UInt8](message.serialized) == expected)
        let header = ADBMessage.parseHeader(from: message.serialized)
        #expect(header?.dataLength == 3)
        #expect(header?.command == ADBCommand.connect.rawValue)
    }

    @Test("Повреждённые magic и checksum отвергаются")
    func corruptedHeaderAndPayloadAreRejected() {
        let valid = ADBMessage(command: .write, arg0: 1, arg1: 2, data: Data([1, 2, 3]))
        let badMagic = ADBMessage(
            command: valid.command,
            arg0: valid.arg0,
            arg1: valid.arg1,
            dataLength: valid.dataLength,
            dataCRC32: valid.dataCRC32,
            magic: 0,
            data: valid.data
        )
        let badChecksum = ADBMessage(
            command: valid.command,
            arg0: valid.arg0,
            arg1: valid.arg1,
            dataLength: valid.dataLength,
            dataCRC32: valid.dataCRC32,
            magic: valid.magic,
            data: Data([1, 2, 4])
        )

        #expect(valid.isValid)
        #expect(!badMagic.isValid)
        #expect(!badChecksum.isValid)
    }

    @Test("Современный CNXN допускает нулевой checksum")
    func modernConnectAllowsZeroChecksum() {
        let message = ADBMessage(
            command: ADBCommand.connect.rawValue,
            arg0: ADBMessage.version,
            arg1: 4_096,
            dataLength: 3,
            dataCRC32: 0,
            magic: ADBCommand.connect.magic,
            data: Data("abc".utf8)
        )

        #expect(message.isValid)
    }

    @Test("Короткий заголовок не читается за пределами буфера")
    func shortHeaderIsRejected() {
        #expect(ADBMessage.parseHeader(from: Data(repeating: 0xFF, count: 23)) == nil)
    }
}
