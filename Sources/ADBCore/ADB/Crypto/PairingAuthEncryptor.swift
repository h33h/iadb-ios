import Foundation
import CryptoKit

final class PairingAuthEncryptor {
    private let key: SymmetricKey
    private var encCounter: UInt64 = 0
    private var decCounter: UInt64 = 0

    private static let hkdfInfo = Data("adb pairing_auth aes-128-gcm key".utf8)

    init(keyMaterial: Data) {
        let inputKey = SymmetricKey(data: keyMaterial)
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: Self.hkdfInfo,
            outputByteCount: 16
        )
    }

    private static func nonceFromCounter(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { buf in
            for i in 0..<8 {
                nonceBytes[i] = buf[i]
            }
        }
        return try AES.GCM.Nonce(data: nonceBytes)
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        let nonce = try Self.nonceFromCounter(encCounter)
        encCounter += 1
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var result = Data(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }

    func decrypt(_ data: Data) throws -> Data {
        guard data.count > 16 else {
            throw PairingAuthError.invalidData
        }
        let nonce = try Self.nonceFromCounter(decCounter)
        decCounter += 1
        let ciphertext = data.dropLast(16)
        let tag = data.suffix(16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum PairingAuthError: LocalizedError {
        case invalidData

        var errorDescription: String? {
            String(localized: "Invalid encrypted pairing data")
        }
    }
}
