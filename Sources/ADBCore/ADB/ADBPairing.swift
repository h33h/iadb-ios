import Foundation
import Network
import Security
import CryptoKit

/// Выполняет сопряжение беспроводного ADB через TLS и SPAKE2.
public final class ADBPairing: @unchecked Sendable {

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    /// Ошибки согласования и проверки секрета сопряжения.
    public enum PairingError: LocalizedError {
        case invalidCode
        case invalidQRPassword
        case connectionFailed(String)
        case tlsFailed(String)
        case pairingRejected
        case timeout
        case spake2Failed(String)
        case protocolError(String)

        public var errorDescription: String? {
            switch self {
            case .invalidCode: return String(localized: "Invalid pairing code")
            case .invalidQRPassword: return String(localized: "Invalid QR pairing password")
            case .connectionFailed(let m): return String(localized: "Pairing connection failed: \(m)")
            case .tlsFailed(let m): return String(localized: "TLS handshake failed: \(m)")
            case .pairingRejected: return String(localized: "Pairing was rejected by the device")
            case .timeout: return String(localized: "Pairing timed out")
            case .spake2Failed(let m): return String(localized: "SPAKE2 key exchange failed: \(m)")
            case .protocolError(let m): return String(localized: "Pairing protocol error: \(m)")
            }
        }
    }

    private static let pairingPacketVersion: UInt8 = 1
    private static let pairingPacketHeaderSize = 6
    private static let peerInfoSize = 8192

    private enum PairingMsgType: UInt8 {
        case spake2Msg = 0
        case peerInfo  = 1
    }

    /// Идентификатор устройства, полученный после успешного сопряжения.
    public struct PeerInfo: Sendable {
        public let name: String
        public let guid: String
    }

    /// Сопрягает устройство по шестизначному коду, показанному на Android.
    public static func pair(host: String, port: UInt16, code: String) async throws -> PeerInfo {
        let normalizedCode = try normalizedPairingCode(code)
        return try await pairValidated(host: host, port: port, secret: normalizedCode)
    }

    /// Сопрягает устройство по произвольному секрету из QR-кода.
    public static func pair(host: String, port: UInt16, qrPassword: String) async throws -> PeerInfo {
        let password = try validatedQRPassword(qrPassword)
        return try await pairValidated(host: host, port: port, secret: password)
    }

    private static func pairValidated(host: String, port: UInt16, secret: String) async throws -> PeerInfo {

        let crypto = try ADBCrypto()
        let publicKeyData = try crypto.adbPublicKey()
        let pubKeyAdbString = String(data: publicKeyData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? "<bad-utf8>"
        ADBCrypto.log.info("PAIRING start endpoint=\(host, privacy: .private(mask: .hash)) origin=\(crypto.keyOrigin, privacy: .public) pubFingerprint=\(crypto.publicKeyFingerprint(), privacy: .private(mask: .hash))")
        ADBCrypto.log.debug("PAIRING adb_pubkey=\(pubKeyAdbString, privacy: .private(mask: .hash))")

        let identity = try crypto.tlsIdentity()

        let (connection, queue, exportedKey) = try await connectTLS(host: host, port: port, identity: identity)
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

        var passwordData = Data(secret.utf8)
        passwordData.append(exportedKey)
        let spake2: SPAKE2Client
        do {
            spake2 = try SPAKE2Client(password: passwordData)
        } catch {
            throw PairingError.spake2Failed(error.localizedDescription)
        }

        try await sendPairingMessage(connection: connection, type: .spake2Msg, data: spake2.outgoingMessage)

        let spake2Response = try await receivePairingMessage(connection: connection, queue: queue)
        guard spake2Response.type == .spake2Msg else {
            throw PairingError.protocolError("Expected SPAKE2 message, got type \(spake2Response.type.rawValue)")
        }

        let keyMaterial: Data
        do {
            keyMaterial = try spake2.processServerMessage(spake2Response.data)
        } catch {
            throw PairingError.spake2Failed(error.localizedDescription)
        }

        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        let ourPeerInfo = buildPeerInfo(publicKey: publicKeyData)
        let encryptedPeerInfo = try encryptor.encrypt(ourPeerInfo)
        try await sendPairingMessage(connection: connection, type: .peerInfo, data: encryptedPeerInfo)

        let peerInfoResponse = try await receivePairingMessage(connection: connection, queue: queue)
        guard peerInfoResponse.type == .peerInfo else {
            throw PairingError.protocolError("Expected PeerInfo message, got type \(peerInfoResponse.type.rawValue)")
        }

        let decryptedPeerInfo: Data
        do {
            decryptedPeerInfo = try encryptor.decrypt(peerInfoResponse.data)
        } catch {
            throw PairingError.pairingRejected
        }

        let peer = try parsePeerInfo(decryptedPeerInfo)
        ADBCrypto.log.info("PAIRING success endpoint=\(host, privacy: .private(mask: .hash)) deviceName=\(peer.name, privacy: .private(mask: .hash))")
            return peer
        } onCancel: {
            connection.cancel()
        }
    }

    /// Преобразует локализованные цифры кода в ASCII и проверяет длину.
    static func normalizedPairingCode(_ code: String) throws -> String {
        guard let normalized = DecimalDigits.asciiDigits(code),
              normalized.count == 6 else { throw PairingError.invalidCode }
        return normalized
    }

    static func validatedQRPassword(_ password: String) throws -> String {
        guard !password.isEmpty else { throw PairingError.invalidQRPassword }
        return password
    }

    /// Извлекает имя Bonjour-сервиса и секрет из QR-строки Android.
    public static func parseQRCode(_ qrString: String) -> (serviceName: String, password: String)? {
        guard qrString.hasPrefix("WIFI:") else { return nil }

        var serviceName: String?
        var password: String?
        var type: String?

        var parts: [String] = []
        var part = ""
        var escaping = false
        for character in qrString.dropFirst(5) {
            if escaping {
                part.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == ";" {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        guard !escaping else { return nil }
        if !part.isEmpty { parts.append(part) }

        for part in parts {
            if part.hasPrefix("T:") {
                guard type == nil else { return nil }
                type = String(part.dropFirst(2))
            } else if part.hasPrefix("S:") {
                guard serviceName == nil else { return nil }
                serviceName = String(part.dropFirst(2))
            } else if part.hasPrefix("P:") {
                guard password == nil else { return nil }
                password = String(part.dropFirst(2))
            }
        }

        guard type == "ADB", let sn = serviceName, !sn.isEmpty,
              let pw = password, !pw.isEmpty else { return nil }
        return (sn, pw)
    }

    private static let tlsTimeout: TimeInterval = 30
    private static let receiveTimeout: TimeInterval = 15

    private static let exportedKeySize = 64

    private static let exportedKeyLabel = "adb-label"
    private static let exportedKeyLabelSize = 10

    private static func connectTLS(host: String, port: UInt16, identity: SecIdentity) async throws -> (NWConnection, DispatchQueue, Data) {
        let queue = DispatchQueue(label: "com.iadb.pairing")

        let tlsOptions = NWProtocolTLS.Options()

        let capturedMetadata = LockedValue<sec_protocol_metadata_t?>(nil)

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { metadata, _, completionHandler in
                capturedMetadata.write(metadata)
                completionHandler(true)
            },
            queue
        )

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )

        guard let secIdentity = sec_identity_create(identity) else {
            throw PairingError.tlsFailed("Failed to create sec_identity_t from SecIdentity")
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentity
        )

        let parameters = NWParameters(tls: tlsOptions)
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PairingError.connectionFailed("Invalid port: \(port)")
        }
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let lastWaitingError = LockedValue<NWError?>(nil)
                let gate = ResumeGate()

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.claim() {
                            continuation.resume()
                        }
                    case .waiting(let error):

                        lastWaitingError.write(error)
                    case .failed(let error):
                        if gate.claim() {
                            continuation.resume(throwing: PairingError.tlsFailed(error.localizedDescription))
                        }
                    case .cancelled:
                        if gate.claim() {
                            continuation.resume(throwing: PairingError.connectionFailed("Cancelled"))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)

                queue.asyncAfter(deadline: .now() + tlsTimeout) {
                    guard gate.claim() else { return }
                    connection.cancel()
                    if let waitError = lastWaitingError.read() {
                        continuation.resume(throwing: PairingError.connectionFailed(
                            "Connection stuck (\(waitError.localizedDescription)). Check that Local Network permission is granted and both devices are on the same WiFi."
                        ))
                    } else {
                        continuation.resume(throwing: PairingError.timeout)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        try Task.checkCancellation()

        guard let metadata = capturedMetadata.read() else {
            connection.cancel()
            throw PairingError.tlsFailed("TLS metadata not available for key export")
        }

        let ekmDispatchData: dispatch_data_t? = exportedKeyLabel.withCString { labelPtr in
            sec_protocol_metadata_create_secret(
                metadata,
                exportedKeyLabelSize,
                labelPtr,
                exportedKeySize
            )
        }
        guard let ekmDispatchData = ekmDispatchData else {
            connection.cancel()
            throw PairingError.tlsFailed("Failed to export TLS keying material")
        }

        let dispatchData = ekmDispatchData as DispatchData
        let ekm = dispatchData.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) in
            Data(bytes: pointer, count: dispatchData.count)
        }
        guard ekm.count == exportedKeySize else {
            connection.cancel()
            throw PairingError.tlsFailed("Unexpected TLS keying material length: \(ekm.count)")
        }
        return (connection, queue, ekm)
    }

    private static func buildPeerInfo(publicKey: Data) -> Data {
        var data = Data(count: peerInfoSize)
        data[0] = 0
        let keyLen = min(publicKey.count, peerInfoSize - 1)
        data.replaceSubrange(1..<(1 + keyLen), with: publicKey.prefix(keyLen))
        return data
    }

    static func parsePeerInfo(_ data: Data) throws -> PeerInfo {
        guard data.count == peerInfoSize else {
            throw PairingError.protocolError("PeerInfo must be exactly \(peerInfoSize) bytes")
        }

        guard data[0] == 1 else {
            throw PairingError.protocolError("Unexpected PeerInfo type: \(data[0])")
        }
        let guidData = data.dropFirst()
        guard let nullIndex = guidData.firstIndex(of: 0), nullIndex > guidData.startIndex else {
            throw PairingError.protocolError("Device GUID is missing or not terminated")
        }
        let encodedGUID = guidData[guidData.startIndex..<nullIndex]
        guard let guid = String(data: encodedGUID, encoding: .utf8),
              !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingError.protocolError("Device GUID is not valid UTF-8")
        }
        return PeerInfo(name: "Android Device", guid: guid)
    }

    private static func sendPairingMessage(connection: NWConnection, type: PairingMsgType, data: Data) async throws {
        var packet = Data()
        packet.append(pairingPacketVersion)
        packet.append(type.rawValue)
        var length = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(data)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: PairingError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receivePairingMessage(connection: NWConnection, queue: DispatchQueue) async throws -> (type: PairingMsgType, data: Data) {
        let header = try await receiveExact(connection: connection, queue: queue, count: pairingPacketHeaderSize)

        guard header[0] == pairingPacketVersion else {
            throw PairingError.protocolError("Unsupported pairing version: \(header[0])")
        }

        guard let msgType = PairingMsgType(rawValue: header[1]) else {
            throw PairingError.protocolError("Unknown message type: \(header[1])")
        }

        let payloadLength: UInt32 = header.withUnsafeBytes { buf in
            let b2 = UInt32(buf[2]) << 24
            let b3 = UInt32(buf[3]) << 16
            let b4 = UInt32(buf[4]) << 8
            let b5 = UInt32(buf[5])
            return b2 | b3 | b4 | b5
        }

        guard payloadLength < 16384 else {
            throw PairingError.protocolError("Payload too large: \(payloadLength)")
        }

        let payload = try await receiveExact(connection: connection, queue: queue, count: Int(payloadLength))
        return (msgType, payload)
    }

    private static func receiveExact(connection: NWConnection, queue: DispatchQueue, count: Int) async throws -> Data {
        var buffer = Data()
        let deadline = DispatchTime.now() + receiveTimeout
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = ResumeGate()

                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error = error {
                        if gate.claim() {
                            continuation.resume(throwing: PairingError.connectionFailed(error.localizedDescription))
                        }
                    } else if let data = data, !data.isEmpty {
                        if gate.claim() {
                            continuation.resume(returning: data)
                        }
                    } else if isComplete {
                        if gate.claim() {
                            continuation.resume(throwing: PairingError.connectionFailed("Connection closed by device"))
                        }
                    } else {
                        if gate.claim() {
                            continuation.resume(throwing: PairingError.connectionFailed("No data received"))
                        }
                    }
                }

                queue.asyncAfter(deadline: deadline) {
                    if gate.claim() {
                        continuation.resume(throwing: PairingError.timeout)
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}
