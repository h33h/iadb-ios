import Foundation

/// High-level ADB client managing connections, authentication, and command execution
final class ADBClient: @unchecked Sendable {
    private let transport = ADBTransport()
    private let crypto: ADBCrypto
    private var nextLocalId: UInt32 = 1
    private let idLock = NSLock()
    private(set) var deviceBanner: String = ""
    private(set) var maxData: UInt32 = 4096

    var isConnected: Bool { transport.isConnected }

    init() throws {
        self.crypto = try ADBCrypto()
    }

    // MARK: - Connection

    /// Connect to an Android device via the _adb-tls-connect port (Android 11+ Wireless Debugging).
    ///
    /// Implements the STLS protocol flow per AOSP:
    /// 1. Plain TCP connect
    /// 2. Client sends CNXN
    /// 3. Server responds with A_STLS (requests TLS upgrade)
    /// 4. Client sends A_STLS back
    /// 5. TLS 1.3 handshake with mTLS (client cert from pairing)
    /// 6. Server sends CNXN over TLS (connection established)
    func connect(host: String, port: UInt16 = 5555) async throws {
        let identity = try crypto.tlsIdentity()

        // Step 1: Plain TCP connection
        try await transport.connect(host: host, port: port)

        // Step 2: Send CNXN
        let connectMsg = ADBMessage.connectMessage()
        try await transport.sendMessage(connectMsg)

        // Step 3: Wait for server response
        let response = try await transport.receiveMessage(timeout: 30)

        switch response.commandType {
        case .stls:
            // Step 4: Server requests TLS upgrade — send A_STLS back
            let stlsMsg = ADBMessage.stlsMessage()
            try await transport.sendMessage(stlsMsg)

            // Step 5: Upgrade to TLS 1.3 with our client certificate.
            // startSecureConnection() completes enqueued writes (A_STLS) first.
            transport.upgradeTLS(identity: identity)

            // Step 6: Wait for CNXN from server over TLS
            let cnxnResponse = try await transport.receiveMessage(timeout: 30)
            guard cnxnResponse.commandType == .connect else {
                throw ADBError.protocolError(
                    "Expected CNXN after TLS, got \(String(format: "0x%08X", cnxnResponse.command))"
                )
            }
            handleConnectResponse(cnxnResponse)

        case .connect:
            // Device responded with CNXN directly (no TLS required)
            handleConnectResponse(response)

        case .auth:
            // Legacy AUTH flow (non-TLS or not yet trusted)
            try await handleAuth(response)

        default:
            throw ADBError.protocolError(
                "Unexpected response: \(String(format: "0x%08X", response.command))"
            )
        }
    }

    func disconnect() {
        transport.disconnect()
        deviceBanner = ""
    }

    private func handleAuth(_ authMessage: ADBMessage) async throws {
        guard authMessage.arg0 == ADBAuthType.token.rawValue else {
            throw ADBError.protocolError("Unexpected auth type: \(authMessage.arg0)")
        }

        // Step 1: Sign the token with our key and send signature
        let signature = try crypto.sign(token: authMessage.data)
        let signMsg = ADBMessage.authSignature(signature)
        try await transport.sendMessage(signMsg)

        // Step 2: Check response — CNXN means device already trusts our key
        let signResponse = try await transport.receiveMessage(timeout: 5)

        if signResponse.commandType == .connect {
            handleConnectResponse(signResponse)
            return
        }

        // Step 3: Device doesn't trust us yet — send our public key
        // Device should show authorization dialog to the user
        let pubKeyData = try crypto.adbPublicKey()
        let pubKeyMsg = ADBMessage.authRSAPublicKey(pubKeyData)
        try await transport.sendMessage(pubKeyMsg)

        // Step 4: Wait for user to tap "Allow" on device (up to 60 seconds)
        let acceptResponse = try await transport.receiveMessage(timeout: 60)

        guard acceptResponse.commandType == .connect else {
            throw ADBError.authenticationFailed
        }
        handleConnectResponse(acceptResponse)
    }

    private func handleConnectResponse(_ message: ADBMessage) {
        maxData = message.arg1
        deviceBanner = message.dataString?.trimmingCharacters(in: .controlCharacters) ?? ""
    }

    // MARK: - Stream Management

    private func allocateLocalId() -> UInt32 {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextLocalId
        nextLocalId += 1
        return id
    }

    /// Open a stream to the given destination (e.g., "shell:ls", "sync:")
    func openStream(destination: String) async throws -> ADBStream {
        let localId = allocateLocalId()
        let openMsg = ADBMessage.openMessage(localId: localId, destination: destination)
        try await transport.sendMessage(openMsg)

        let response = try await transport.receiveMessage()
        guard response.commandType == .ready else {
            if response.commandType == .close {
                throw ADBError.commandFailed("Stream rejected for: \(destination)")
            }
            throw ADBError.protocolError("Expected OKAY, got \(String(format: "0x%08X", response.command))")
        }

        let remoteId = response.arg0
        return ADBStream(localId: localId, remoteId: remoteId, transport: transport)
    }

    // MARK: - Shell Commands

    /// Execute a shell command and return the output
    func shell(_ command: String) async throws -> String {
        let stream = try await openStream(destination: "shell:\(command)")

        var output = Data()
        do {
            while true {
                let message = try await transport.receiveMessage()
                switch message.commandType {
                case .write:
                    output.append(message.data)
                    try await transport.sendMessage(
                        ADBMessage.readyMessage(localId: stream.localId, remoteId: stream.remoteId)
                    )
                case .close:
                    return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                default:
                    continue
                }
            }
        } catch {
            try? await stream.close()
            throw error
        }
    }

    // MARK: - Device Info

    func getDeviceProperty(_ property: String) async throws -> String {
        return try await shell("getprop \(property)")
    }

    func getDeviceModel() async throws -> String {
        return try await getDeviceProperty("ro.product.model")
    }

    func getAndroidVersion() async throws -> String {
        return try await getDeviceProperty("ro.build.version.release")
    }

    func getSDKVersion() async throws -> String {
        return try await getDeviceProperty("ro.build.version.sdk")
    }

    func getBatteryLevel() async throws -> String {
        return try await shell("dumpsys battery | grep level")
    }

    func getDeviceSerial() async throws -> String {
        return try await getDeviceProperty("ro.serialno")
    }

    // MARK: - App Management

    func listPackages(includeSystem: Bool = false) async throws -> [String] {
        let flag = includeSystem ? "" : "-3"
        let output = try await shell("pm list packages \(flag)")
        return output.components(separatedBy: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("package:") else { return nil }
                return String(trimmed.dropFirst("package:".count))
            }
            .sorted()
    }

    func installAPK(localPath: String, remoteTempPath: String = "/data/local/tmp/install.apk") async throws -> String {
        // Push APK to device first, then install
        try await pushFile(localPath: localPath, remotePath: remoteTempPath)
        let result = try await shell("pm install -r \"\(remoteTempPath)\"")
        _ = try? await shell("rm \"\(remoteTempPath)\"")
        return result
    }

    func uninstallPackage(_ packageName: String, keepData: Bool = false) async throws -> String {
        let flag = keepData ? "-k" : ""
        return try await shell("pm uninstall \(flag) \(packageName)")
    }

    func forceStopApp(_ packageName: String) async throws {
        _ = try await shell("am force-stop \(packageName)")
    }

    func clearAppData(_ packageName: String) async throws -> String {
        return try await shell("pm clear \(packageName)")
    }

    func getAppInfo(_ packageName: String) async throws -> String {
        return try await shell("dumpsys package \(packageName)")
    }

    // MARK: - File Operations

    func listDirectory(_ path: String) async throws -> String {
        return try await shell("ls -la \(path)")
    }

    func pushFile(localPath: String, remotePath: String) async throws {
        let fileData: Data
        if localPath.hasPrefix("/") || localPath.hasPrefix("file://") {
            let url = localPath.hasPrefix("file://") ? URL(string: localPath)! : URL(fileURLWithPath: localPath)
            fileData = try Data(contentsOf: url)
        } else {
            throw ADBError.fileTransferFailed("Invalid local path")
        }
        try await pushData(fileData, to: remotePath)
    }

    func pushData(_ data: Data, to remotePath: String, mode: UInt32 = 0o644) async throws {
        let stream = try await openStream(destination: "sync:")

        do { // SEND command
        let sendHeader = "SEND"
        let pathAndMode = "\(remotePath),\(mode)"
        let pathData = pathAndMode.data(using: .utf8)!

        var sendCmd = Data()
        sendCmd.append(sendHeader.data(using: .utf8)!)
        sendCmd.append(contentsOf: withUnsafeBytes(of: UInt32(pathData.count).littleEndian) { Array($0) })
        sendCmd.append(pathData)
        try await transport.sendMessage(
            ADBMessage.writeMessage(localId: stream.localId, remoteId: stream.remoteId, data: sendCmd)
        )

        // Wait for OKAY
        _ = try await transport.receiveMessage()

        let chunkSize = Int(maxData) - 8
        guard chunkSize > 0 else {
            throw ADBError.protocolError("maxData too small: \(maxData)")
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]

            var dataCmd = Data()
            dataCmd.append("DATA".data(using: .utf8)!)
            dataCmd.append(contentsOf: withUnsafeBytes(of: UInt32(chunk.count).littleEndian) { Array($0) })
            dataCmd.append(chunk)

            try await transport.sendMessage(
                ADBMessage.writeMessage(localId: stream.localId, remoteId: stream.remoteId, data: dataCmd)
            )
            _ = try await transport.receiveMessage()

            offset = end
        }

        // DONE command with mtime
        let mtime = UInt32(Date().timeIntervalSince1970)
        var doneCmd = Data()
        doneCmd.append("DONE".data(using: .utf8)!)
        doneCmd.append(contentsOf: withUnsafeBytes(of: mtime.littleEndian) { Array($0) })
        try await transport.sendMessage(
            ADBMessage.writeMessage(localId: stream.localId, remoteId: stream.remoteId, data: doneCmd)
        )

        // Read OKAY or FAIL
        let response = try await transport.receiveMessage()
        if response.commandType == .write {
            if let text = response.dataString, text.hasPrefix("FAIL") {
                let errorMsg = text.count > 8 ? String(text.dropFirst(8)) : "Unknown sync error"
                throw ADBError.fileTransferFailed(errorMsg)
            }
        } else if response.commandType == .close {
            throw ADBError.fileTransferFailed("Stream closed unexpectedly during sync")
        }
        } catch {
            try? await stream.close()
            throw error
        }
    }

    func pullFile(remotePath: String) async throws -> Data {
        let stream = try await openStream(destination: "sync:")

        do {
            let pathData = remotePath.data(using: .utf8)!
            var recvCmd = Data()
            recvCmd.append("RECV".data(using: .utf8)!)
            recvCmd.append(contentsOf: withUnsafeBytes(of: UInt32(pathData.count).littleEndian) { Array($0) })
            recvCmd.append(pathData)

            try await transport.sendMessage(
                ADBMessage.writeMessage(localId: stream.localId, remoteId: stream.remoteId, data: recvCmd)
            )

            _ = try await transport.receiveMessage()

            var fileData = Data()
            while true {
                let msg = try await transport.receiveMessage()
                guard msg.commandType == .write else { break }

                let payload = msg.data
                guard payload.count >= 8 else { continue }

                let tag = String(data: payload[0..<4], encoding: .utf8) ?? ""
                let length = payload.withUnsafeBytes { buf in
                    buf.load(fromByteOffset: 4, as: UInt32.self).littleEndian
                }

                if tag == "DATA" {
                    guard 8 + Int(length) <= payload.count else {
                        throw ADBError.protocolError("DATA chunk length exceeds payload size")
                    }
                    let chunk = payload[8..<(8 + Int(length))]
                    fileData.append(chunk)
                    try await transport.sendMessage(
                        ADBMessage.readyMessage(localId: stream.localId, remoteId: stream.remoteId)
                    )
                } else if tag == "DONE" {
                    break
                } else if tag == "FAIL" {
                    let errorMsg = String(data: payload[8...], encoding: .utf8) ?? "Unknown error"
                    throw ADBError.fileTransferFailed(errorMsg)
                }
            }

            return fileData
        } catch {
            try? await stream.close()
            throw error
        }
    }

    // MARK: - Screenshots

    func takeScreenshot() async throws -> Data {
        _ = try await shell("screencap -p /sdcard/screenshot_iadb.png")
        let data = try await pullFile(remotePath: "/sdcard/screenshot_iadb.png")
        _ = try? await shell("rm /sdcard/screenshot_iadb.png")
        return data
    }

    // MARK: - Logcat

    func openLogcatStream() async throws -> ADBStream {
        return try await openStream(destination: "shell:logcat -v threadtime")
    }

    // MARK: - Reboot

    func reboot(mode: String = "") async throws {
        let cmd = mode.isEmpty ? "reboot" : "reboot \(mode)"
        _ = try await shell(cmd)
    }
}
