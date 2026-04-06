import Foundation
import Network
import Security
import CryptoKit

/// ADB pairing protocol implementation (Android 11+)
///
/// Protocol flow:
/// 1. TLS 1.3 connection to the pairing port (accept self-signed certs)
/// 2. SPAKE2 key exchange using the 6-digit pairing code
/// 3. HKDF-SHA256 key derivation → AES-128-GCM encryption key
/// 4. Exchange of encrypted PeerInfo (RSA public key)
final class ADBPairing: @unchecked Sendable {

    enum PairingError: LocalizedError {
        case invalidCode
        case connectionFailed(String)
        case tlsFailed(String)
        case pairingRejected
        case timeout
        case spake2Failed(String)
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .invalidCode: return "Invalid pairing code"
            case .connectionFailed(let m): return "Pairing connection failed: \(m)"
            case .tlsFailed(let m): return "TLS handshake failed: \(m)"
            case .pairingRejected: return "Pairing was rejected by the device"
            case .timeout: return "Pairing timed out"
            case .spake2Failed(let m): return "SPAKE2 key exchange failed: \(m)"
            case .protocolError(let m): return "Pairing protocol error: \(m)"
            }
        }
    }

    private static let pairingPacketVersion: UInt8 = 1
    private static let pairingPacketHeaderSize = 6
    private static let peerInfoSize = 8192 // Fixed PeerInfo struct size per AOSP

    private enum PairingMsgType: UInt8 {
        case spake2Msg = 0
        case peerInfo  = 1
    }

    struct PeerInfo {
        let name: String
        let guid: String
        let publicKey: Data
    }

    /// Pair with an Android device using the 6-digit pairing code.
    static func pair(host: String, port: UInt16, code: String, deviceName: String = "iADB") async throws -> PeerInfo {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate pairing code: must be 6 digits
        guard trimmedCode.count == 6,
              trimmedCode.allSatisfy({ $0.isNumber }) else {
            throw PairingError.invalidCode
        }

        // Generate RSA key pair for ADB auth
        let crypto = try ADBCrypto()
        let publicKeyData = try crypto.adbPublicKey()

        // Step 1: TLS connection
        let (connection, queue) = try await connectTLS(host: host, port: port)
        defer { connection.cancel() }

        // Step 2: SPAKE2 key exchange
        let passwordData = Data(trimmedCode.utf8)
        let spake2: SPAKE2Client
        do {
            spake2 = try SPAKE2Client(password: passwordData)
        } catch {
            throw PairingError.spake2Failed(error.localizedDescription)
        }

        // Send our SPAKE2 message
        try await sendPairingMessage(connection: connection, queue: queue, type: .spake2Msg, data: spake2.outgoingMessage)

        // Receive server's SPAKE2 message
        let spake2Response = try await receivePairingMessage(connection: connection, queue: queue)
        guard spake2Response.type == .spake2Msg else {
            throw PairingError.protocolError("Expected SPAKE2 message, got type \(spake2Response.type.rawValue)")
        }

        // Step 3: Derive encryption key
        let keyMaterial: Data
        do {
            keyMaterial = try spake2.processServerMessage(spake2Response.data)
        } catch {
            throw PairingError.spake2Failed(error.localizedDescription)
        }

        let encryptor = PairingAuthEncryptor(keyMaterial: keyMaterial)

        // Step 4: Exchange encrypted PeerInfo
        let ourPeerInfo = buildPeerInfo(publicKey: publicKeyData)
        let encryptedPeerInfo = try encryptor.encrypt(ourPeerInfo)
        try await sendPairingMessage(connection: connection, queue: queue, type: .peerInfo, data: encryptedPeerInfo)

        // Receive and decrypt device's PeerInfo
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

        return try parsePeerInfo(decryptedPeerInfo)
    }

    /// Parse a QR code string from Android wireless debugging.
    /// Format: WIFI:T:ADB;S:<service_name>;P:<password>;;
    static func parseQRCode(_ qrString: String) -> (serviceName: String, password: String)? {
        guard qrString.hasPrefix("WIFI:") else { return nil }

        var serviceName: String?
        var password: String?

        let content = String(qrString.dropFirst(5))
        let parts = content.components(separatedBy: ";")

        for part in parts {
            if part.hasPrefix("S:") {
                serviceName = String(part.dropFirst(2))
            } else if part.hasPrefix("P:") {
                password = String(part.dropFirst(2))
            }
        }

        guard let sn = serviceName, let pw = password else { return nil }
        return (sn, pw)
    }

    // MARK: - TLS Connection

    private static let tlsTimeout: TimeInterval = 30
    private static let receiveTimeout: TimeInterval = 15

    private static func connectTLS(host: String, port: UInt16) async throws -> (NWConnection, DispatchQueue) {
        let queue = DispatchQueue(label: "com.iadb.pairing")

        let tlsOptions = NWProtocolTLS.Options()

        // Accept self-signed certificates (ADB uses self-signed)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completionHandler in
                completionHandler(true)
            },
            queue
        )

        // Require TLS 1.3 (AOSP pairing server mandates TLS 1.3)
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )

        let parameters = NWParameters(tls: tlsOptions)
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: nwHost, port: nwPort, using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let lock = NSLock()

            func safeResume(_ block: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                block()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    safeResume { continuation.resume() }
                case .waiting(let error):
                    // Connection cannot proceed — typically Local Network
                    // permission denied or network unreachable.
                    // Fail fast instead of waiting for the timeout.
                    safeResume {
                        connection.cancel()
                        continuation.resume(throwing: PairingError.connectionFailed(
                            "Network unavailable (\(error.localizedDescription)). Check that Local Network permission is granted and both devices are on the same WiFi."
                        ))
                    }
                case .failed(let error):
                    safeResume { continuation.resume(throwing: PairingError.tlsFailed(error.localizedDescription)) }
                case .cancelled:
                    safeResume { continuation.resume(throwing: PairingError.connectionFailed("Cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + tlsTimeout) {
                safeResume {
                    connection.cancel()
                    continuation.resume(throwing: PairingError.timeout)
                }
            }
        }

        return (connection, queue)
    }

    // MARK: - PeerInfo

    /// Build PeerInfo: exactly 8192 bytes (1 byte type + 8191 bytes data, zero-padded).
    private static func buildPeerInfo(publicKey: Data) -> Data {
        var data = Data(count: peerInfoSize)
        data[0] = 0 // ADB_RSA_PUB_KEY = 0
        let keyLen = min(publicKey.count, peerInfoSize - 1)
        data.replaceSubrange(1..<(1 + keyLen), with: publicKey.prefix(keyLen))
        return data
    }

    /// Parse decrypted PeerInfo (8192 bytes).
    private static func parsePeerInfo(_ data: Data) throws -> PeerInfo {
        guard data.count >= 2 else {
            throw PairingError.protocolError("PeerInfo too short")
        }

        let keyData = data.dropFirst(1)
        // Find null terminator in key data
        let nullIdx = keyData.firstIndex(of: 0) ?? keyData.endIndex
        let keySlice = keyData[keyData.startIndex..<nullIdx]
        let keyString = String(data: keySlice, encoding: .utf8) ?? ""

        // Extract device name from the key string (after the base64 key)
        let name = keyString.components(separatedBy: " ").last ?? "Android Device"

        return PeerInfo(
            name: name.isEmpty ? "Android Device" : name,
            guid: "",
            publicKey: Data(keySlice)
        )
    }

    // MARK: - Message Framing

    /// Send a pairing protocol message. Header: version(1) + type(1) + payload_length(4 BE).
    private static func sendPairingMessage(connection: NWConnection, queue: DispatchQueue, type: PairingMsgType, data: Data) async throws {
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

    /// Receive a pairing protocol message.
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

        // Encrypted PeerInfo can be up to ~8220 bytes
        guard payloadLength < 16384 else {
            throw PairingError.protocolError("Payload too large: \(payloadLength)")
        }

        let payload = try await receiveExact(connection: connection, queue: queue, count: Int(payloadLength))
        return (msgType, payload)
    }

    private static func receiveExact(connection: NWConnection, queue: DispatchQueue, count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                let lock = NSLock()

                func safeResume(_ block: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    block()
                }

                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error = error {
                        safeResume { continuation.resume(throwing: PairingError.connectionFailed(error.localizedDescription)) }
                    } else if let data = data, !data.isEmpty {
                        safeResume { continuation.resume(returning: data) }
                    } else if isComplete {
                        safeResume { continuation.resume(throwing: PairingError.connectionFailed("Connection closed by device")) }
                    } else {
                        safeResume { continuation.resume(throwing: PairingError.connectionFailed("No data received")) }
                    }
                }

                queue.asyncAfter(deadline: .now() + receiveTimeout) {
                    safeResume { continuation.resume(throwing: PairingError.timeout) }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}
