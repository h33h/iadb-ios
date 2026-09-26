import CryptoKit
import Foundation
import Testing
@testable import ADBCore

@Suite("Сопряжение")
struct PairingTests {
    @Test("Код из локализованных цифр превращается в ASCII")
    func localizedCodeIsNormalized() throws {
        #expect(try ADBPairing.normalizedPairingCode(" ١٢٣٤٥٦ ") == "123456")
        #expect(try ADBPairing.normalizedPairingCode("１２３４５６") == "123456")
    }

    @Test("Некорректный код отвергается до обращения к Keychain", arguments: ["123", "1234567", "abc123", "ⅠⅡⅢⅣⅤⅥ"])
    func invalidManualCodeIsRejected(_ code: String) async {
        do {
            _ = try await ADBPairing.pair(host: "192.0.2.1", port: 5555, code: code)
            Issue.record("Некорректный код принят")
        } catch ADBPairing.PairingError.invalidCode {
        } catch {
            Issue.record("Получена другая ошибка: \(error)")
        }
    }

    @Test("QR-секрет сохраняет экранированные разделители")
    func qrPasswordPreservesEscapedCharacters() throws {
        let qr = "WIFI:T:ADB;S:studio\\;pixel;P:foo\\;bar\\\\baz\\:qux;;"
        let result = try #require(ADBPairing.parseQRCode(qr))

        #expect(result.serviceName == "studio;pixel")
        #expect(result.password == "foo;bar\\baz:qux")
    }

    @Test("QR с чужим типом или пустым паролем отвергается", arguments: [
        "WIFI:T:WPA;S:pixel;P:secret;;",
        "WIFI:T:ADB;S:pixel;P:;;",
        "WIFI:T:ADB;S:;P:secret;;",
    ])
    func malformedQRIsRejected(_ qr: String) {
        #expect(ADBPairing.parseQRCode(qr) == nil)
    }

    @Test("Исходящее сообщение SPAKE2 принадлежит подгруппе простого порядка")
    func outgoingMessageHasNoTorsionComponent() throws {
        let password = Data("000000".utf8) + Data(repeating: 0xAB, count: 64)
        let client = try SPAKE2Client(password: password)
        let point = try #require(EdPoint.decode([UInt8](client.outgoingMessage)))
        let order: [UInt8] = [
            0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58,
            0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        ]

        #expect(point.scalarMult(order).isIdentity)
    }

    @Test("Некорректная точка сервера SPAKE2 отвергается")
    func invalidServerPointIsRejected() throws {
        let client = try SPAKE2Client(password: Data("123456".utf8))
        var invalid = [UInt8](repeating: 0, count: 32)
        invalid[0] = 1
        invalid[31] = 0x80

        do {
            _ = try client.processServerMessage(Data(invalid))
            Issue.record("Некорректная точка сервера принята")
        } catch SPAKE2Client.SPAKE2Error.invalidMessage {
        }
    }

    @Test("Сообщение с неверной меткой AES-GCM отвергается")
    func modifiedCiphertextIsRejected() throws {
        let material = Data(SHA256.hash(data: Data("pairing-key".utf8)))
        let encryptor = PairingAuthEncryptor(keyMaterial: material)
        var ciphertext = try encryptor.encrypt(Data("payload".utf8))
        ciphertext[ciphertext.count - 1] ^= 1

        do {
            _ = try encryptor.decrypt(ciphertext)
            Issue.record("Изменённый шифротекст принят")
        } catch {
        }
    }

    @Test("PeerInfo извлекает GUID устройства из бинарного ответа")
    func peerInfoExtractsDeviceGUID() throws {
        var message = Data(count: 8_192)
        message[0] = 1
        let guid = Data("adb-device-guid-123".utf8)
        message.replaceSubrange(1..<(1 + guid.count), with: guid)

        let peer = try ADBPairing.parsePeerInfo(message)

        #expect(peer.guid == "adb-device-guid-123")
    }

    @Test("PeerInfo отвергает чужой тип и неполный пакет")
    func malformedPeerInfoIsRejected() {
        for message in [Data(count: 8_192), Data(count: 10)] {
            do {
                _ = try ADBPairing.parsePeerInfo(message)
                Issue.record("Некорректный PeerInfo принят")
            } catch ADBPairing.PairingError.protocolError {
            } catch {
                Issue.record("Получена другая ошибка: \(error)")
            }
        }
    }

}
