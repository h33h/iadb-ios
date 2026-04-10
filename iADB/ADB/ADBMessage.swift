import Foundation

/// ADB protocol message types
enum ADBCommand: UInt32 {
    case connect    = 0x4e584e43  // CNXN
    case auth       = 0x48545541  // AUTH
    case open       = 0x4e45504f  // OPEN
    case ready      = 0x59414b4f  // OKAY
    case close      = 0x45534c43  // CLSE
    case write      = 0x45545257  // WRTE
    case stls       = 0x534c5453  // STLS — запрос TLS-апгрейда (Android 11+)

    var magic: UInt32 {
        return rawValue ^ 0xFFFFFFFF
    }
}

/// ADB authentication types
enum ADBAuthType: UInt32 {
    case token      = 1
    case signature  = 2
    case rsaPublic  = 3
}

/// Represents a single ADB protocol message
struct ADBMessage {
    static let headerSize = 24
    static let maxPayload: UInt32 = 1024 * 1024
    static let version: UInt32 = 0x01000001       // ADB version (skip-checksum capable)
    static let stlsVersion: UInt32 = 0x01000000   // A_STLS_VERSION per AOSP

    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let dataLength: UInt32
    let dataCRC32: UInt32
    let magic: UInt32
    let data: Data

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

    /// Serialize message header to bytes
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

    /// Full serialized message (header + data)
    var serialized: Data {
        var result = headerBytes
        result.append(data)
        return result
    }

    /// Parse header from raw bytes
    static func parseHeader(from data: Data) -> (command: UInt32, arg0: UInt32, arg1: UInt32, dataLength: UInt32, dataCRC32: UInt32, magic: UInt32)? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { buf in
            let command = buf.load(fromByteOffset: 0, as: UInt32.self).littleEndian
            let arg0 = buf.load(fromByteOffset: 4, as: UInt32.self).littleEndian
            let arg1 = buf.load(fromByteOffset: 8, as: UInt32.self).littleEndian
            let dataLength = buf.load(fromByteOffset: 12, as: UInt32.self).littleEndian
            let dataCRC32 = buf.load(fromByteOffset: 16, as: UInt32.self).littleEndian
            let magic = buf.load(fromByteOffset: 20, as: UInt32.self).littleEndian
            return (command, arg0, arg1, dataLength, dataCRC32, magic)
        }
    }

    /// Simple checksum used by ADB protocol
    static func checksum(_ data: Data) -> UInt32 {
        return data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    /// Validate message integrity
    var isValid: Bool {
        return isValid(skipChecksum: false)
    }

    /// После TLS (ADB v0x01000001) устройство может слать dataCRC32=0
    func isValid(skipChecksum: Bool) -> Bool {
        guard command ^ magic == 0xFFFFFFFF else { return false }
        if skipChecksum { return true }
        return dataCRC32 == ADBMessage.checksum(data)
    }

    var commandType: ADBCommand? {
        return ADBCommand(rawValue: command)
    }

    var dataString: String? {
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Factory Methods

    static func connectMessage(banner: String = "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,sendrecv_v2_dry_run_send,openscreen_mdns") -> ADBMessage {
        let bannerData = banner.data(using: .utf8)! + Data([0])
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
        let destData = destination.data(using: .utf8)! + Data([0])
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
