import Foundation

/// Команды транспортного протокола ADB.
public enum ADBCommand: UInt32 {
    case connect    = 0x4e584e43
    case auth       = 0x48545541
    case open       = 0x4e45504f
    case ready      = 0x59414b4f
    case close      = 0x45534c43
    case write      = 0x45545257
    case stls       = 0x534c5453

    var magic: UInt32 {
        return rawValue ^ 0xFFFFFFFF
    }
}

enum ADBAuthType: UInt32 {
    case token      = 1
    case signature  = 2
    case rsaPublic  = 3
}

/// Заголовок и полезная нагрузка одного сообщения ADB.
public struct ADBMessage: Sendable {
    static let headerSize = 24
    static let maxPayload: UInt32 = 1024 * 1024
    static let version: UInt32 = 0x01000001
    static let stlsVersion: UInt32 = 0x01000000

    public let command: UInt32
    public let arg0: UInt32
    public let arg1: UInt32
    let dataLength: UInt32
    let dataCRC32: UInt32
    let magic: UInt32
    public let data: Data

    init(command: ADBCommand, arg0: UInt32, arg1: UInt32, data: Data = Data()) {
        self.command = command.rawValue
        self.arg0 = arg0
        self.arg1 = arg1
        self.dataLength = UInt32(data.count)
        self.dataCRC32 = ADBMessage.checksum(data)
        self.magic = command.magic
        self.data = data
    }

    init(command: UInt32, arg0: UInt32, arg1: UInt32, dataLength: UInt32, dataCRC32: UInt32, magic: UInt32, data: Data) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.dataLength = dataLength
        self.dataCRC32 = dataCRC32
        self.magic = magic
        self.data = data
    }

    var headerBytes: Data {
        var header = Data(capacity: ADBMessage.headerSize)
        header.append(contentsOf: withUnsafeBytes(of: command.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: arg0.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: arg1.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: dataLength.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: dataCRC32.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: magic.littleEndian) { Array($0) })
        return header
    }

    var serialized: Data {
        var result = headerBytes
        result.append(data)
        return result
    }

    static func parseHeader(from data: Data) -> (command: UInt32, arg0: UInt32, arg1: UInt32, dataLength: UInt32, dataCRC32: UInt32, magic: UInt32)? {
        guard data.count >= headerSize else { return nil }

        return data.withUnsafeBytes { buf in
            let command = buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let arg0 = buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let arg1 = buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
            let dataLength = buf.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
            let dataCRC32 = buf.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian
            let magic = buf.loadUnaligned(fromByteOffset: 20, as: UInt32.self).littleEndian
            return (command, arg0, arg1, dataLength, dataCRC32, magic)
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        return data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    var isValid: Bool {
        return isValid(skipChecksum: false)
    }

    func isValid(skipChecksum: Bool) -> Bool {
        guard command ^ magic == 0xFFFFFFFF else { return false }
        if skipChecksum || isModernConnectWithZeroChecksum { return true }
        return dataCRC32 == ADBMessage.checksum(data)
    }

    private var isModernConnectWithZeroChecksum: Bool {
        commandType == .connect && arg0 >= ADBMessage.version && dataCRC32 == 0
    }

    public var commandType: ADBCommand? {
        return ADBCommand(rawValue: command)
    }

    public var dataString: String? {
        return String(data: data, encoding: .utf8)
    }

    static func connectMessage(banner: String = "host::features=shell_v2,stat_v2,ls_v2") -> ADBMessage {
        let bannerData = Data(banner.utf8) + Data([0])
        return ADBMessage(command: .connect, arg0: version, arg1: maxPayload, data: bannerData)
    }

    static func authSignature(_ signedToken: Data) -> ADBMessage {
        return ADBMessage(command: .auth, arg0: ADBAuthType.signature.rawValue, arg1: 0, data: signedToken)
    }

    static func authRSAPublicKey(_ publicKey: Data) -> ADBMessage {
        var keyData = publicKey
        if keyData.last != 0 {
            keyData.append(0)
        }
        return ADBMessage(command: .auth, arg0: ADBAuthType.rsaPublic.rawValue, arg1: 0, data: keyData)
    }

    static func openMessage(localId: UInt32, destination: String) -> ADBMessage {
        let destData = Data(destination.utf8) + Data([0])
        return ADBMessage(command: .open, arg0: localId, arg1: 0, data: destData)
    }

    static func readyMessage(localId: UInt32, remoteId: UInt32) -> ADBMessage {
        return ADBMessage(command: .ready, arg0: localId, arg1: remoteId)
    }

    static func writeMessage(localId: UInt32, remoteId: UInt32, data: Data) -> ADBMessage {
        return ADBMessage(command: .write, arg0: localId, arg1: remoteId, data: data)
    }

    static func closeMessage(localId: UInt32, remoteId: UInt32) -> ADBMessage {
        return ADBMessage(command: .close, arg0: localId, arg1: remoteId)
    }

    static func stlsMessage() -> ADBMessage {
        return ADBMessage(command: .stls, arg0: stlsVersion, arg1: 0)
    }
}
