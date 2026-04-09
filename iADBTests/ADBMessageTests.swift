import Foundation
import XCTest
@testable import iADB

final class ADBMessageTests: XCTestCase {

    // MARK: - ADBCommand

    func testCommandRawValues() {
        XCTAssertEqual(ADBCommand.connect.rawValue, 0x4e584e43)
        XCTAssertEqual(ADBCommand.auth.rawValue, 0x48545541)
        XCTAssertEqual(ADBCommand.open.rawValue, 0x4e45504f)
        XCTAssertEqual(ADBCommand.ready.rawValue, 0x59414b4f)
        XCTAssertEqual(ADBCommand.close.rawValue, 0x45534c43)
        XCTAssertEqual(ADBCommand.write.rawValue, 0x45545257)
    }

    func testCommandMagic() {
        // Magic is command XOR 0xFFFFFFFF
        for cmd in [ADBCommand.connect, .auth, .open, .ready, .close, .write] {
            XCTAssertEqual(cmd.rawValue ^ cmd.magic, 0xFFFFFFFF)
        }
    }

    func testAuthTypeValues() {
        XCTAssertEqual(ADBAuthType.token.rawValue, 1)
        XCTAssertEqual(ADBAuthType.signature.rawValue, 2)
        XCTAssertEqual(ADBAuthType.rsaPublic.rawValue, 3)
    }

    // MARK: - Constants

    func testHeaderSize() {
        XCTAssertEqual(ADBMessage.headerSize, 24)
    }

    func testMaxPayload() {
        XCTAssertEqual(ADBMessage.maxPayload, 1024 * 1024)
    }

    func testVersion() {
        XCTAssertEqual(ADBMessage.version, 0x01000001)
    }

    func testStlsVersion() {
        XCTAssertEqual(ADBMessage.stlsVersion, 0x01000000)
    }

    // MARK: - Checksum

    func testChecksumEmpty() {
        XCTAssertEqual(ADBMessage.checksum(Data()), 0)
    }

    func testChecksumSingleByte() {
        XCTAssertEqual(ADBMessage.checksum(Data([0x42])), 0x42)
    }

    func testChecksumMultipleBytes() {
        let data = Data([1, 2, 3, 4, 5])
        XCTAssertEqual(ADBMessage.checksum(data), 15)
    }

    func testChecksumAllFF() {
        let data = Data([0xFF, 0xFF, 0xFF])
        XCTAssertEqual(ADBMessage.checksum(data), 255 * 3)
    }

    func testChecksumKnownString() {
        let data = "hello".data(using: .utf8)!
        // h=104, e=101, l=108, l=108, o=111 = 532
        XCTAssertEqual(ADBMessage.checksum(data), 532)
    }

    // MARK: - Message Creation

    func testCreateMessageNoData() {
        let msg = ADBMessage(command: .ready, arg0: 1, arg1: 2)
        XCTAssertEqual(msg.command, ADBCommand.ready.rawValue)
        XCTAssertEqual(msg.arg0, 1)
        XCTAssertEqual(msg.arg1, 2)
        XCTAssertEqual(msg.dataLength, 0)
        XCTAssertEqual(msg.dataCRC32, 0)
        XCTAssertEqual(msg.magic, ADBCommand.ready.magic)
        XCTAssertTrue(msg.data.isEmpty)
    }

    func testCreateMessageWithData() {
        let payload = "test".data(using: .utf8)!
        let msg = ADBMessage(command: .write, arg0: 10, arg1: 20, data: payload)
        XCTAssertEqual(msg.command, ADBCommand.write.rawValue)
        XCTAssertEqual(msg.dataLength, UInt32(payload.count))
        XCTAssertEqual(msg.dataCRC32, ADBMessage.checksum(payload))
        XCTAssertEqual(msg.data, payload)
    }

    func testMessageIsValid() {
        let msg = ADBMessage(command: .connect, arg0: 0, arg1: 0, data: Data([1, 2, 3]))
        XCTAssertTrue(msg.isValid)
    }

    func testMessageIsInvalidBadMagic() {
        let msg = ADBMessage(
            command: ADBCommand.connect.rawValue,
            arg0: 0, arg1: 0,
            dataLength: 0, dataCRC32: 0,
            magic: 0x12345678, // Wrong magic
            data: Data()
        )
        XCTAssertFalse(msg.isValid)
    }

    func testMessageIsInvalidBadChecksum() {
        let msg = ADBMessage(
            command: ADBCommand.connect.rawValue,
            arg0: 0, arg1: 0,
            dataLength: 3, dataCRC32: 999, // Wrong checksum
            magic: ADBCommand.connect.magic,
            data: Data([1, 2, 3])
        )
        XCTAssertFalse(msg.isValid)
    }

    func testMessageIsValidSkipChecksum() {
        // Simulates a post-TLS message where the device sends dataCRC32 = 0
        let msg = ADBMessage(
            command: ADBCommand.connect.rawValue,
            arg0: 0, arg1: 0,
            dataLength: 3, dataCRC32: 0, // Device skips checksum after TLS
            magic: ADBCommand.connect.magic,
            data: Data([1, 2, 3])
        )
        XCTAssertFalse(msg.isValid) // Strict validation fails
        XCTAssertTrue(msg.isValid(skipChecksum: true)) // Skip-checksum passes
    }

    func testMessageSkipChecksumStillValidatesMagic() {
        let msg = ADBMessage(
            command: ADBCommand.connect.rawValue,
            arg0: 0, arg1: 0,
            dataLength: 0, dataCRC32: 0,
            magic: 0x12345678, // Wrong magic
            data: Data()
        )
        XCTAssertFalse(msg.isValid(skipChecksum: true)) // Magic must still match
    }

    // MARK: - Serialization

    func testHeaderBytesSize() {
        let msg = ADBMessage(command: .ready, arg0: 0, arg1: 0)
        XCTAssertEqual(msg.headerBytes.count, 24)
    }

    func testSerializedSizeNoPayload() {
        let msg = ADBMessage(command: .close, arg0: 1, arg1: 2)
        XCTAssertEqual(msg.serialized.count, 24)
    }

    func testSerializedSizeWithPayload() {
        let payload = Data(repeating: 0xAB, count: 100)
        let msg = ADBMessage(command: .write, arg0: 1, arg1: 2, data: payload)
        XCTAssertEqual(msg.serialized.count, 24 + 100)
    }

    func testHeaderBytesLittleEndian() {
        let msg = ADBMessage(command: .connect, arg0: 1, arg1: 2)
        let header = msg.headerBytes
        // First 4 bytes should be CNXN command in little endian
        let commandLE = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(commandLE, ADBCommand.connect.rawValue.littleEndian)
    }

    func testSerializationRoundTrip() {
        let payload = "hello world".data(using: .utf8)!
        let original = ADBMessage(command: .write, arg0: 42, arg1: 99, data: payload)
        let serialized = original.serialized

        // Parse header
        let headerData = serialized[0..<24]
        guard let header = ADBMessage.parseHeader(from: headerData) else {
            XCTFail("Failed to parse header")
            return
        }

        XCTAssertEqual(header.command, original.command)
        XCTAssertEqual(header.arg0, original.arg0)
        XCTAssertEqual(header.arg1, original.arg1)
        XCTAssertEqual(header.dataLength, original.dataLength)
        XCTAssertEqual(header.dataCRC32, original.dataCRC32)
        XCTAssertEqual(header.magic, original.magic)

        // Verify payload
        let payloadData = serialized[24...]
        XCTAssertEqual(Data(payloadData), payload)
    }

    // MARK: - Header Parsing

    func testParseHeaderTooShort() {
        let shortData = Data(repeating: 0, count: 20)
        XCTAssertNil(ADBMessage.parseHeader(from: shortData))
    }

    func testParseHeaderExactSize() {
        let msg = ADBMessage(command: .open, arg0: 5, arg1: 10, data: Data([0xFF]))
        let header = ADBMessage.parseHeader(from: msg.headerBytes)
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.command, ADBCommand.open.rawValue)
        XCTAssertEqual(header?.arg0, 5)
        XCTAssertEqual(header?.arg1, 10)
        XCTAssertEqual(header?.dataLength, 1)
    }

    func testParseHeaderLargerBuffer() {
        // Extra bytes after header should be ignored
        var data = ADBMessage(command: .ready, arg0: 0, arg1: 0).headerBytes
        data.append(Data(repeating: 0xFF, count: 100))
        let header = ADBMessage.parseHeader(from: data)
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.command, ADBCommand.ready.rawValue)
    }

    // MARK: - Command Type

    func testCommandTypeValid() {
        let msg = ADBMessage(command: .auth, arg0: 0, arg1: 0)
        XCTAssertEqual(msg.commandType, .auth)
    }

    func testCommandTypeUnknown() {
        let msg = ADBMessage(
            command: 0xDEADBEEF,
            arg0: 0, arg1: 0,
            dataLength: 0, dataCRC32: 0,
            magic: 0xDEADBEEF ^ 0xFFFFFFFF,
            data: Data()
        )
        XCTAssertNil(msg.commandType)
    }

    // MARK: - Data String

    func testDataStringUTF8() {
        let msg = ADBMessage(command: .write, arg0: 0, arg1: 0, data: "hello".data(using: .utf8)!)
        XCTAssertEqual(msg.dataString, "hello")
    }

    func testDataStringEmpty() {
        let msg = ADBMessage(command: .ready, arg0: 0, arg1: 0)
        XCTAssertEqual(msg.dataString, "")
    }

    // MARK: - Factory Methods

    func testConnectMessage() {
        let msg = ADBMessage.connectMessage()
        XCTAssertEqual(msg.commandType, .connect)
        XCTAssertEqual(msg.arg0, ADBMessage.version)
        XCTAssertEqual(msg.arg1, ADBMessage.maxPayload)
        // Payload should end with null byte
        XCTAssertEqual(msg.data.last, 0)
        // Payload should contain "host::"
        let str = String(data: msg.data.dropLast(), encoding: .utf8)!
        XCTAssertTrue(str.hasPrefix("host::"))
    }

    func testConnectMessageCustomBanner() {
        let msg = ADBMessage.connectMessage(banner: "test_banner")
        let str = String(data: msg.data.dropLast(), encoding: .utf8)!
        XCTAssertEqual(str, "test_banner")
    }

    func testAuthSignatureMessage() {
        let sig = Data([0x01, 0x02, 0x03])
        let msg = ADBMessage.authSignature(sig)
        XCTAssertEqual(msg.commandType, .auth)
        XCTAssertEqual(msg.arg0, ADBAuthType.signature.rawValue)
        XCTAssertEqual(msg.arg1, 0)
        XCTAssertEqual(msg.data, sig)
    }

    func testAuthRSAPublicKeyMessage() {
        let key = "testkey".data(using: .utf8)!
        let msg = ADBMessage.authRSAPublicKey(key)
        XCTAssertEqual(msg.commandType, .auth)
        XCTAssertEqual(msg.arg0, ADBAuthType.rsaPublic.rawValue)
        // Should append null byte
        XCTAssertEqual(msg.data.last, 0)
        XCTAssertEqual(msg.data.count, key.count + 1)
    }

    func testOpenMessage() {
        let msg = ADBMessage.openMessage(localId: 7, destination: "shell:ls")
        XCTAssertEqual(msg.commandType, .open)
        XCTAssertEqual(msg.arg0, 7)
        XCTAssertEqual(msg.arg1, 0)
        // Null-terminated destination
        XCTAssertEqual(msg.data.last, 0)
        let dest = String(data: msg.data.dropLast(), encoding: .utf8)
        XCTAssertEqual(dest, "shell:ls")
    }

    func testReadyMessage() {
        let msg = ADBMessage.readyMessage(localId: 3, remoteId: 5)
        XCTAssertEqual(msg.commandType, .ready)
        XCTAssertEqual(msg.arg0, 3)
        XCTAssertEqual(msg.arg1, 5)
        XCTAssertTrue(msg.data.isEmpty)
    }

    func testWriteMessage() {
        let payload = Data([0xCA, 0xFE])
        let msg = ADBMessage.writeMessage(localId: 1, remoteId: 2, data: payload)
        XCTAssertEqual(msg.commandType, .write)
        XCTAssertEqual(msg.arg0, 1)
        XCTAssertEqual(msg.arg1, 2)
        XCTAssertEqual(msg.data, payload)
    }

    func testCloseMessage() {
        let msg = ADBMessage.closeMessage(localId: 8, remoteId: 9)
        XCTAssertEqual(msg.commandType, .close)
        XCTAssertEqual(msg.arg0, 8)
        XCTAssertEqual(msg.arg1, 9)
        XCTAssertTrue(msg.data.isEmpty)
    }

    // MARK: - Wire Format Validation

    func testKnownWireBytes() {
        // Manually construct a CNXN with known bytes and verify parsing
        var raw = Data()
        // command = CNXN = 0x4e584e43 LE
        raw.append(contentsOf: [0x43, 0x4e, 0x58, 0x4e])
        // arg0 = version 0x01000001 LE
        raw.append(contentsOf: [0x01, 0x00, 0x00, 0x01])
        // arg1 = maxPayload 4096 = 0x00001000 LE
        raw.append(contentsOf: [0x00, 0x10, 0x00, 0x00])
        // dataLength = 0
        raw.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // dataCRC32 = 0
        raw.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // magic = CNXN ^ 0xFFFFFFFF = 0xB1A7B1BC LE
        let magic = UInt32(0x4e584e43) ^ 0xFFFFFFFF
        raw.append(contentsOf: withUnsafeBytes(of: magic.littleEndian) { Array($0) })

        let header = ADBMessage.parseHeader(from: raw)
        XCTAssertNotNil(header)
        XCTAssertEqual(header?.command, ADBCommand.connect.rawValue)
        XCTAssertEqual(header?.arg0, 0x01000001)
        XCTAssertEqual(header?.arg1, 4096)
    }

    // MARK: - All Commands Round Trip

    func testAllCommandsSerializeRoundTrip() {
        let commands: [ADBCommand] = [.connect, .auth, .open, .ready, .close, .write]
        for cmd in commands {
            let payload = "\(cmd)_data".data(using: .utf8)!
            let msg = ADBMessage(command: cmd, arg0: 100, arg1: 200, data: payload)
            let bytes = msg.serialized

            guard let header = ADBMessage.parseHeader(from: bytes) else {
                XCTFail("Failed to parse \(cmd)")
                continue
            }

            let rebuilt = ADBMessage(
                command: header.command, arg0: header.arg0, arg1: header.arg1,
                dataLength: header.dataLength, dataCRC32: header.dataCRC32,
                magic: header.magic, data: Data(bytes[24...])
            )

            XCTAssertTrue(rebuilt.isValid, "Validation failed for \(cmd)")
            XCTAssertEqual(rebuilt.command, msg.command)
            XCTAssertEqual(rebuilt.arg0, msg.arg0)
            XCTAssertEqual(rebuilt.arg1, msg.arg1)
            XCTAssertEqual(rebuilt.data, msg.data)
        }
    }
}
