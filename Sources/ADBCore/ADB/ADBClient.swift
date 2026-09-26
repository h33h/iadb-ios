import Foundation

/// Состояние передачи файла в байтах.
public struct TransferProgress: Equatable, Sendable {
    public let completedUnits: Int64
    public let totalUnits: Int64?
}

/// Пакет вывода или код завершения команды shell v2.
public enum ShellEvent: Equatable, Sendable {
    case stdout(Data)
    case stderr(Data)
    case exit(Int32)
}

func adbShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Управляет соединением ADB и предоставляет операции над устройством.
public final class ADBClient: @unchecked Sendable {
    private struct ConnectionMetadata: Sendable {
        var banner = ""
        var maxData: UInt32 = 4_096
    }

    private static let syncChunkSize = 64 * 1024
    private static let maximumShellOutputSize = 8 * 1024 * 1024
    public static let maximumInMemoryTransferSize = 64 * 1024 * 1024

    private let transport: any ADBClientTransport
    private let router: ADBMessageRouter
    private let identity: any ADBSigningIdentity
    private var nextLocalId: UInt32 = 1
    private let idLock = NSLock()
    private let metadataLock = NSLock()
    private var metadata = ConnectionMetadata()

    public var deviceBanner: String { metadataLock.withLock { metadata.banner } }
    public var maxData: UInt32 { metadataLock.withLock { metadata.maxData } }

    public var isConnected: Bool { transport.isConnected }

    /// Создаёт клиент с сохранённым ключом ADB и TLS-транспортом.
    public convenience init() throws {
        let crypto = try ADBCrypto()
        let transport = ADBTransportSTLS(identity: try crypto.tlsIdentity())
        self.init(transport: transport, identity: crypto)
    }

    init(transport: any ADBClientTransport, identity: any ADBSigningIdentity) {
        self.identity = identity
        self.transport = transport
        self.router = ADBMessageRouter(transport: transport)
    }

    deinit {
        transport.disconnect()
    }

    /// Экранирует один аргумент для команды Android shell.
    public static func shellQuote(_ value: String) -> String {
        adbShellQuote(value)
    }

    /// Подключается к устройству и завершает согласование протокола.
    /// Самоподписанный сертификат сервера не сверяется с идентификатором устройства.
    public func connect(host: String, port: UInt16 = 5555) async throws {
        await router.reset()
        metadataLock.withLock { metadata = ConnectionMetadata() }
        let keyOrigin = identity.keyOrigin
        let fingerprint = identity.publicKeyFingerprint()
        ADBCrypto.log.info("CONNECT start host=\(host, privacy: .private(mask: .hash)): highly private endpoint")
        ADBCrypto.log.debug(
            "CONNECT identity origin=\(keyOrigin, privacy: .public) fingerprint=\(fingerprint, privacy: .private(mask: .hash))"
        )

        do {
            try await transport.connect(host: host, port: port, timeout: 15)
            try await transport.sendMessage(.connectMessage())

            let response = try await transport.receiveMessage(timeout: 15)
            switch response.commandType {
            case .stls:
                try await handleSTLS()
            case .connect:
                handleConnectResponse(response)
            case .auth:
                try await handleAuth(response)
            default:
                throw ADBError.protocolError(
                    "Expected STLS/CNXN/AUTH, got \(String(format: "0x%08X", response.command))"
                )
            }
        } catch {
            transport.disconnect()
            metadataLock.withLock { metadata = ConnectionMetadata() }
            await router.shutdown(error: error)
            throw error
        }
    }

    private func handleSTLS() async throws {
        try await transport.sendMessage(.stlsMessage())
        try await transport.upgradeToTLS()

        let response = try await transport.receiveMessage(timeout: 30)
        switch response.commandType {
        case .connect:
            handleConnectResponse(response)
        case .auth:
            try await handleAuth(response)
        default:
            throw ADBError.protocolError(
                "Expected CNXN/AUTH after TLS, got \(String(format: "0x%08X", response.command))"
            )
        }
    }

    /// Закрывает транспорт и дожидается остановки маршрутизатора потоков.
    public func disconnect() async {
        transport.disconnect()
        metadataLock.withLock { metadata = ConnectionMetadata() }
        await router.shutdown()
    }

    private func handleAuth(_ authMessage: ADBMessage) async throws {
        guard authMessage.arg0 == ADBAuthType.token.rawValue else {
            throw ADBError.protocolError("Unexpected auth type: \(authMessage.arg0)")
        }

        try await transport.sendMessage(.authSignature(try identity.sign(token: authMessage.data)))
        let signResponse = try await transport.receiveMessage(timeout: 5)
        if signResponse.commandType == .connect {
            handleConnectResponse(signResponse)
            return
        }

        try await transport.sendMessage(.authRSAPublicKey(try identity.adbPublicKey()))
        let acceptResponse = try await transport.receiveMessage(timeout: 60)
        guard acceptResponse.commandType == .connect else {
            throw ADBError.authenticationFailed
        }
        handleConnectResponse(acceptResponse)
    }

    private func handleConnectResponse(_ message: ADBMessage) {
        metadataLock.withLock {
            metadata.maxData = message.arg1
            metadata.banner = message.dataString?.trimmingCharacters(in: .controlCharacters) ?? ""
        }
    }

    private func allocateLocalId() -> UInt32 {
        idLock.withLock {
            let id = nextLocalId
            nextLocalId &+= 1
            if nextLocalId == 0 { nextLocalId = 1 }
            return id
        }
    }

    /// Открывает логический поток для службы ADB.
    public func openStream(destination: String, timeout: TimeInterval = 15) async throws -> ADBStream {
        try Task.checkCancellation()
        let localId = allocateLocalId()
        let inbox = try await router.register(localId: localId)

        do {
            try await transport.sendMessage(.openMessage(localId: localId, destination: destination))
            while true {
                let response = try await inbox.next(timeout: timeout)
                switch response.commandType {
                case .ready:
                    guard response.arg0 != 0 else {
                        throw ADBError.protocolError("ADB accepted a stream with remote id 0")
                    }
                    return ADBStream(
                        localId: localId,
                        remoteId: response.arg0,
                        transport: transport,
                        router: router,
                        inbox: inbox
                    )
                case .close:

                    if response.arg0 != 0 {
                        try? await transport.sendMessage(
                            .closeMessage(localId: localId, remoteId: response.arg0)
                        )
                    }
                    throw ADBError.commandFailed("Stream rejected for: \(destination)")
                default:
                    throw ADBError.protocolError(
                        "Expected OKAY, got \(String(format: "0x%08X", response.command))"
                    )
                }
            }
        } catch {
            await router.unregister(localId: localId, error: error)
            throw error
        }
    }

}

extension ADBClient {

    /// Выполняет команду shell v2 и возвращает её текстовый вывод.
    public func shell(_ command: String) async throws -> String {
        try await shellV2(command)
    }

    /// Выполняет команду shell v2 с потоковой выдачей stdout, stderr и кода выхода.
    public func openShellCommand(
        _ command: String
    ) async throws -> AsyncThrowingStream<ShellEvent, Error> {
        let stream = try await openStream(destination: "shell,v2,raw:\(command)")
        return shellV2EventStream(stream)
    }

    private func shellV2EventStream(
        _ stream: ADBStream
    ) -> AsyncThrowingStream<ShellEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let decoder = ShellV2Decoder()
                var emittedBytes = 0
                do {
                    while true {
                        try Task.checkCancellation()
                        let message = try await stream.readMessage()
                        switch message.commandType {
                        case .write:
                            try await stream.sendReady()
                            decoder.append(message.data)
                            for packet in try decoder.takePackets() {
                                switch packet.id {
                                case .stdout, .stderr:
                                    guard packet.data.count <= Self.maximumShellOutputSize - emittedBytes else {
                                        throw ADBError.commandFailed("Command output exceeded the 8 MiB safety limit")
                                    }
                                    emittedBytes += packet.data.count
                                    continuation.yield(packet.id == .stdout ? .stdout(packet.data) : .stderr(packet.data))
                                case .exit:
                                    guard let code = packet.exitCode,
                                          let exitCode = Int32(exactly: code) else {
                                        throw ADBError.protocolError("Malformed shell v2 EXIT packet")
                                    }
                                    continuation.yield(.exit(exitCode))
                                    try await stream.close()
                                    continuation.finish()
                                    return
                                default:
                                    continue
                                }
                            }
                        case .close:
                            await stream.acknowledgeRemoteClose()
                            throw ADBError.protocolError("shell,v2 closed without an EXIT packet")
                        default:
                            continue
                        }
                    }
                } catch is CancellationError {
                    try? await stream.close()
                    continuation.finish()
                } catch {
                    try? await stream.close()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func shellV2(_ command: String) async throws -> String {
        let stream = try await openStream(destination: "shell,v2,raw:\(command)")
        return try await shellV2(over: stream)
    }

    private func shellV2(over stream: ADBStream) async throws -> String {
        let decoder = ShellV2Decoder()
        var output = Data()
        var exitCode: Int?

        do {
            while exitCode == nil {
                try Task.checkCancellation()
                let message = try await stream.readMessage()
                switch message.commandType {
                case .write:
                    try await stream.sendReady()
                    decoder.append(message.data)
                    for packet in try decoder.takePackets() {
                        switch packet.id {
                        case .stdout, .stderr:
                            try appendShellOutput(packet.data, to: &output)
                        case .exit:
                            guard let code = packet.exitCode else {
                                throw ADBError.protocolError("Malformed shell v2 EXIT packet")
                            }
                            exitCode = code
                        default:
                            continue
                        }
                    }
                case .close:
                    await stream.acknowledgeRemoteClose()
                    throw ADBError.protocolError("shell,v2 closed without an EXIT packet")
                default:
                    continue
                }
            }

            try await stream.close()
            let text = decodeShellOutput(output)
            guard exitCode == 0 else {
                let detail = text.isEmpty ? "No output" : text
                throw ADBError.commandFailed("Exit status \(exitCode ?? -1): \(detail)")
            }
            return text
        } catch {
            try? await stream.close()
            throw error
        }
    }

    private func appendShellOutput(_ chunk: Data, to output: inout Data) throws {
        guard chunk.count <= Self.maximumShellOutputSize,
              output.count <= Self.maximumShellOutputSize - chunk.count else {
            throw ADBError.commandFailed(
                "Command output exceeded the \(Self.maximumShellOutputSize / 1_048_576) MiB safety limit"
            )
        }
        output.append(chunk)
    }

    private func decodeShellOutput(_ data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

extension ADBClient {

    public func getDeviceProperty(_ property: String) async throws -> String {
        try await shell("getprop \(adbShellQuote(property))")
    }

    public func getAndroidVersion() async throws -> String {
        try await getDeviceProperty("ro.build.version.release")
    }

    public func getSDKVersion() async throws -> String {
        try await getDeviceProperty("ro.build.version.sdk")
    }

    public func getBatteryLevel() async throws -> String {
        try await shell("dumpsys battery | grep level")
    }

    public func getDeviceSerial() async throws -> String {
        try await getDeviceProperty("ro.serialno")
    }

    public func listPackages(includeSystem: Bool = false) async throws -> [String] {
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

    public func uninstallPackage(_ packageName: String, keepData: Bool = false) async throws -> String {
        let flag = keepData ? "-k " : ""
        return try await shell("pm uninstall \(flag)\(adbShellQuote(packageName))")
    }

    public func forceStopApp(_ packageName: String) async throws {
        _ = try await shell("am force-stop \(adbShellQuote(packageName))")
    }

    public func clearAppData(_ packageName: String) async throws -> String {
        try await shell("pm clear \(adbShellQuote(packageName))")
    }

}

extension ADBClient {

    /// Читает каталог через бинарный протокол SYNC LIST_V2.
    public func listDirectoryEntries(_ path: String) async throws -> [FileEntry] {
        let stream = try await openStream(destination: "sync:")
        do {
            let pathData = Data(path.utf8)
            try await sendServiceBytes(
                SyncFrame.encoded(id: .statV2, value: UInt32(pathData.count), data: pathData),
                over: stream
            )

            let stat = try await receiveStatV2(over: stream, decoder: SyncStatV2Decoder())
            guard stat.error == 0 else {
                throw ADBError.fileTransferFailed(
                    Self.syncErrnoDescription(stat.error, operation: "Open", path: path)
                )
            }
            guard stat.mode & 0o170000 == 0o040000 else {
                throw ADBError.fileTransferFailed("Not a directory: \(path)")
            }
            try await verifyDirectoryAccess(path)

            try await sendServiceBytes(
                SyncFrame.encoded(id: .listV2, value: UInt32(pathData.count), data: pathData),
                over: stream
            )

            let decoder = SyncDirectoryV2Decoder()
            var entries: [FileEntry] = []
            while true {
                try Task.checkCancellation()
                switch try await receiveDirectoryRecord(over: stream, decoder: decoder) {
                case .entry(let mode, let size, let modificationTime, let nameData):
                    let name = String(decoding: nameData, as: UTF8.self)
                    guard name != ".", name != ".." else { continue }
                    entries.append(
                        Self.fileEntry(
                            name: name,
                            parentPath: path,
                            mode: mode,
                            size: size,
                            modificationTime: modificationTime
                        )
                    )
                case .done:
                    try await stream.close()
                    return entries
                case .failure(let message):
                    throw ADBError.fileTransferFailed(message)
                }
            }
        } catch {
            try? await stream.close()
            throw error
        }
    }

    private func verifyDirectoryAccess(_ path: String) async throws {
        let quotedPath = adbShellQuote(path)
        do {
            _ = try await shell("test -r \(quotedPath) && test -x \(quotedPath) || exit 13")
        } catch ADBError.commandFailed(let message)
            where message.hasPrefix("Exit status 13:") {
            throw ADBError.fileTransferFailed("Open failed for \(path): Permission denied")
        }
    }

    /// Передаёт локальный файл на устройство без загрузки целиком в память.
    public func pushFile(from localURL: URL, to remotePath: String, mode: UInt32 = 0o644) async throws {
        try await pushFile(from: localURL, to: remotePath, mode: mode) { _ in }
    }

    public func pushFile(
        from localURL: URL,
        to remotePath: String,
        mode: UInt32 = 0o644,
        progress: @Sendable (TransferProgress) async -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let totalUnits = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        try await pushContent(to: remotePath, mode: mode, totalUnits: totalUnits ?? nil, progress: progress) {
            try handle.read(upToCount: Self.syncChunkSize)
        }
    }

    public func pushData(_ data: Data, to remotePath: String, mode: UInt32 = 0o644) async throws {
        var offset = 0
        try await pushContent(to: remotePath, mode: mode, totalUnits: Int64(data.count), progress: { _ in }) {
            guard offset < data.count else { return nil }
            let end = min(offset + Self.syncChunkSize, data.count)
            defer { offset = end }
            return Data(data[offset..<end])
        }
    }

    private func pushContent(
        to remotePath: String,
        mode: UInt32,
        totalUnits: Int64?,
        progress: @Sendable (TransferProgress) async -> Void,
        nextChunk: () throws -> Data?
    ) async throws {
        let stream = try await openStream(destination: "sync:")
        do {
            let pathAndMode = Data("\(remotePath),\(mode)".utf8)
            try await sendServiceBytes(
                SyncFrame.encoded(id: .send, value: UInt32(pathAndMode.count), data: pathAndMode),
                over: stream
            )

            var completedUnits: Int64 = 0
            while let chunk = try nextChunk(), !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= Self.syncChunkSize else {
                    throw ADBError.protocolError("SYNC DATA chunk exceeds 64 KiB")
                }
                try await sendServiceBytes(
                    SyncFrame.encoded(id: .data, value: UInt32(chunk.count), data: chunk),
                    over: stream
                )
                completedUnits += Int64(chunk.count)
                await progress(TransferProgress(
                    completedUnits: completedUnits,
                    totalUnits: totalUnits
                ))
            }

            let modificationTime = UInt32(clamping: Int(Date().timeIntervalSince1970))
            try await sendServiceBytes(
                SyncFrame.encoded(id: .done, value: modificationTime),
                over: stream
            )

            let decoder = SyncFrameDecoder()
            let response = try await receiveSyncFrame(over: stream, decoder: decoder)
            switch response.id {
            case .okay:
                try await stream.close()
            case .fail:
                throw ADBError.fileTransferFailed(response.text ?? "Unknown sync error")
            default:
                throw ADBError.protocolError("Expected SYNC OKAY/FAIL after DONE")
            }
        } catch {
            try? await stream.close()
            throw error
        }
    }

    public func pullFile(
        remotePath: String,
        maximumBytes: Int = ADBClient.maximumInMemoryTransferSize
    ) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= Self.maximumInMemoryTransferSize else {
            throw ADBError.fileTransferFailed("Invalid in-memory transfer limit")
        }
        var result = Data()
        try await pullContent(from: remotePath) { chunk in
            guard result.count <= maximumBytes - chunk.count else {
                throw ADBError.fileTransferFailed(
                    "File exceeds the \(maximumBytes / 1_048_576) MiB "
                        + "in-memory limit; use streaming download"
                )
            }
            result.append(chunk)
        }
        return result
    }

    /// Сохраняет удалённый файл через временный файл с заменой после успешной передачи.
    public func pullFile(remotePath: String, to localURL: URL) async throws {
        try await pullFile(remotePath: remotePath, to: localURL) { _ in }
    }

    public func pullFile(
        remotePath: String,
        to localURL: URL,
        progress: @Sendable (TransferProgress) async -> Void
    ) async throws {
        let temporaryURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".iadb-\(UUID().uuidString).download")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw ADBError.fileTransferFailed("Unable to create the destination file")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            var completedUnits: Int64 = 0
            try await pullContent(from: remotePath) { chunk in
                try handle.write(contentsOf: chunk)
                completedUnits += Int64(chunk.count)
                await progress(TransferProgress(completedUnits: completedUnits, totalUnits: nil))
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func pullContent(
        from remotePath: String,
        consume: (Data) async throws -> Void
    ) async throws {
        let stream = try await openStream(destination: "sync:")
        do {
            let path = Data(remotePath.utf8)
            try await sendServiceBytes(
                SyncFrame.encoded(id: .receive, value: UInt32(path.count), data: path),
                over: stream
            )

            let decoder = SyncFrameDecoder()
            while true {
                try Task.checkCancellation()
                let frame = try await receiveSyncFrame(over: stream, decoder: decoder)
                switch frame.id {
                case .data:
                    try await consume(frame.data)
                case .done:
                    try await stream.close()
                    return
                case .fail:
                    throw ADBError.fileTransferFailed(frame.text ?? "Unknown sync error")
                default:
                    throw ADBError.protocolError("Unexpected SYNC response: \(frame.id.name)")
                }
            }
        } catch {
            try? await stream.close()
            throw error
        }
    }

    private func sendServiceBytes(_ data: Data, over stream: ADBStream) async throws {
        let payloadLimit = min(Int(maxData), Int(ADBMessage.maxPayload))
        guard payloadLimit > 0 else {
            throw ADBError.protocolError("Invalid negotiated maxData: \(maxData)")
        }

        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + payloadLimit, data.count)
            try await stream.write(Data(data[offset..<end]))
            acknowledgementLoop: while true {
                let acknowledgement = try await stream.readMessage(timeout: 30)
                switch acknowledgement.commandType {
                case .ready:
                    break acknowledgementLoop
                case .write:
                    try await stream.sendReady()
                    try stream.deferServiceMessage(acknowledgement)
                case .close:
                    await stream.acknowledgeRemoteClose()
                    throw ADBError.connectionClosed
                default:
                    throw ADBError.protocolError("Expected transport OKAY after WRTE")
                }
            }
            offset = end
        }
    }

    private func receiveSyncFrame(
        over stream: ADBStream,
        decoder: SyncFrameDecoder
    ) async throws -> SyncFrame {
        while true {
            if let frame = try decoder.takeFrame() {
                return frame
            }

            let received = try await stream.readServiceMessage()
            switch received.message.commandType {
            case .write:
                decoder.append(received.message.data)
                if received.needsAcknowledgement { try await stream.sendReady() }
            case .close:
                await stream.acknowledgeRemoteClose()
                throw ADBError.fileTransferFailed("SYNC stream closed before a complete response")
            default:
                continue
            }
        }
    }

    private func receiveDirectoryRecord(
        over stream: ADBStream,
        decoder: SyncDirectoryV2Decoder
    ) async throws -> SyncDirectoryRecord {
        while true {
            if let record = try decoder.takeRecord() {
                return record
            }
            let received = try await stream.readServiceMessage()
            switch received.message.commandType {
            case .write:
                decoder.append(received.message.data)
                if received.needsAcknowledgement { try await stream.sendReady() }
            case .close:
                await stream.acknowledgeRemoteClose()
                throw ADBError.fileTransferFailed("SYNC LIST closed before DONE")
            default:
                continue
            }
        }
    }

    private func receiveStatV2(
        over stream: ADBStream,
        decoder: SyncStatV2Decoder
    ) async throws -> SyncStatV2 {
        while true {
            if let stat = try decoder.takeStat() {
                return stat
            }
            let received = try await stream.readServiceMessage()
            switch received.message.commandType {
            case .write:
                decoder.append(received.message.data)
                if received.needsAcknowledgement { try await stream.sendReady() }
            case .close:
                await stream.acknowledgeRemoteClose()
                throw ADBError.fileTransferFailed("SYNC STAT_V2 closed before a complete response")
            default:
                continue
            }
        }
    }

    private static func fileEntry(
        name: String,
        parentPath: String,
        mode: UInt32,
        size: UInt64,
        modificationTime: Int64
    ) -> FileEntry {
        var parent = parentPath
        while parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        let fullPath = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
        return FileEntry(
            name: name,
            fullPath: fullPath,
            mode: mode,
            size: size,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(modificationTime))
        )
    }

    private static func syncErrnoDescription(
        _ error: UInt32,
        operation: String,
        path: String
    ) -> String {
        let reason = switch error {
        case 2: "No such file or directory"
        case 13: "Permission denied"
        case 20: "Not a directory"
        default: "Android error \(error)"
        }
        return "\(operation) failed for \(path): \(reason)"
    }

}

extension ADBClient {

    static func screenshotRemotePath(id: UUID) -> String {
        "/data/local/tmp/iadb-screenshot-\(id.uuidString).png"
    }

    /// Возвращает снимок экрана устройства в формате PNG.
    public func takeScreenshot() async throws -> Data {
        let remotePath = Self.screenshotRemotePath(id: UUID())
        _ = try await shell("screencap -p \(adbShellQuote(remotePath))")
        do {
            let screenshot = try await pullFile(remotePath: remotePath)
            _ = try? await shell("rm -f -- \(adbShellQuote(remotePath))")
            return screenshot
        } catch {
            _ = try? await shell("rm -f -- \(adbShellQuote(remotePath))")
            throw error
        }
    }

    /// Открывает поток системного журнала Android.
    public func openLogcatStream() async throws -> ADBStream {
        try await openStream(destination: "shell:logcat -v threadtime")
    }

    public func reboot(mode: String = "") async throws {
        let command = mode.isEmpty ? "reboot" : "reboot \(adbShellQuote(mode))"
        let stream = try await openStream(destination: "shell,v2,raw:\(command)")
        do {
            _ = try await shellV2(over: stream)
        } catch ADBError.connectionClosed {

        } catch ADBError.protocolError(let message)
            where message == "shell,v2 closed without an EXIT packet" {

        }
    }
}

private enum ShellV2PacketID: UInt8 {
    case stdin = 0
    case stdout = 1
    case stderr = 2
    case exit = 3
    case closeStdin = 4
    case windowSizeChange = 5
}

private struct ShellV2Packet {
    let id: ShellV2PacketID
    let data: Data

    var exitCode: Int? {
        guard id == .exit, let first = data.first else { return nil }
        if data.count >= 4 {
            return Int(data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
        }
        return Int(first)
    }
}

private final class ShellV2Decoder {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func takePackets() throws -> [ShellV2Packet] {
        var packets: [ShellV2Packet] = []
        while buffer.count >= 5 {
            guard let id = ShellV2PacketID(rawValue: buffer[buffer.startIndex]) else {
                throw ADBError.protocolError("Unknown shell v2 packet id")
            }
            let length = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian
            }
            guard length <= ADBMessage.maxPayload else {
                throw ADBError.protocolError("shell v2 packet is too large")
            }
            let packetLength = 5 + Int(length)
            guard buffer.count >= packetLength else { break }
            let payload = Data(buffer.dropFirst(5).prefix(Int(length)))
            buffer.removeFirst(packetLength)
            packets.append(ShellV2Packet(id: id, data: payload))
        }
        return packets
    }
}

private enum SyncID: UInt32 {
    case list = 0x5453494C
    case dent = 0x544E4544
    case statV2 = 0x32415453
    case listV2 = 0x3253494C
    case dentV2 = 0x32544E44
    case send = 0x444E4553
    case receive = 0x56434552
    case data = 0x41544144
    case done = 0x454E4F44
    case okay = 0x59414B4F
    case fail = 0x4C494146

    var name: String {
        String(bytes: [
            UInt8(rawValue & 0xFF),
            UInt8((rawValue >> 8) & 0xFF),
            UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 24) & 0xFF)
        ], encoding: .ascii) ?? "????"
    }
}

private struct SyncFrame {
    let id: SyncID
    let value: UInt32
    let data: Data

    var text: String? {
        String(data: data, encoding: .utf8)
    }

    static func encoded(id: SyncID, value: UInt32, data: Data = Data()) -> Data {
        var result = Data(capacity: 8 + data.count)
        result.append(contentsOf: withUnsafeBytes(of: id.rawValue.littleEndian) { Array($0) })
        result.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        result.append(data)
        return result
    }
}

private final class SyncFrameDecoder {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func takeFrame() throws -> SyncFrame? {
        guard buffer.count >= 8 else { return nil }
        let rawID = buffer.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        guard let id = SyncID(rawValue: rawID) else {
            throw ADBError.protocolError("Unknown SYNC frame id")
        }
        let value = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }

        let payloadLength: Int
        switch id {
        case .send, .receive, .data, .fail, .list, .statV2, .listV2:
            payloadLength = Int(value)
        case .done, .okay:
            payloadLength = 0
        case .dent, .dentV2:
            throw ADBError.protocolError("DENT requires the SYNC directory decoder")
        }
        guard payloadLength <= Int(ADBMessage.maxPayload) else {
            throw ADBError.protocolError("SYNC frame payload is too large")
        }
        guard buffer.count >= 8 + payloadLength else { return nil }

        let payload = Data(buffer.dropFirst(8).prefix(payloadLength))
        buffer.removeFirst(8 + payloadLength)
        return SyncFrame(id: id, value: value, data: payload)
    }
}

private enum SyncDirectoryRecord {
    case entry(mode: UInt32, size: UInt64, modificationTime: Int64, name: Data)
    case done
    case failure(String)
}

private struct SyncStatV2 {
    let error: UInt32
    let mode: UInt32
    let size: UInt64
    let modificationTime: Int64
}

private final class SyncStatV2Decoder {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func takeStat() throws -> SyncStatV2? {
        guard buffer.count >= 8 else { return nil }
        let rawID = uint32(at: 0)
        if rawID == SyncID.fail.rawValue {
            let messageLength = Int(uint32(at: 4))
            guard messageLength <= Int(ADBMessage.maxPayload) else {
                throw ADBError.protocolError("SYNC STAT_V2 failure message is too large")
            }
            guard buffer.count >= 8 + messageLength else { return nil }
            let message = String(decoding: buffer.dropFirst(8).prefix(messageLength), as: UTF8.self)
            throw ADBError.fileTransferFailed(message)
        }
        guard rawID == SyncID.statV2.rawValue else {
            throw ADBError.protocolError("Unexpected SYNC STAT_V2 response id")
        }
        guard buffer.count >= 72 else { return nil }
        let stat = SyncStatV2(
            error: uint32(at: 4),
            mode: uint32(at: 24),
            size: uint64(at: 40),
            modificationTime: int64(at: 56)
        )
        buffer.removeFirst(72)
        return stat
    }

    private func uint32(at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private func uint64(at offset: Int) -> UInt64 {
        buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    private func int64(at offset: Int) -> Int64 {
        Int64(bitPattern: uint64(at: offset))
    }
}

private final class SyncDirectoryV2Decoder {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func takeRecord() throws -> SyncDirectoryRecord? {
        guard buffer.count >= 8 else { return nil }
        let rawID = uint32(at: 0)
        switch rawID {
        case SyncID.dentV2.rawValue:
            guard buffer.count >= 76 else { return nil }
            let error = uint32(at: 4)
            let mode = uint32(at: 24)
            let size = uint64(at: 40)
            let modificationTime = int64(at: 56)
            let nameLength = Int(uint32(at: 72))
            guard nameLength <= Int(ADBMessage.maxPayload) else {
                throw ADBError.protocolError("SYNC DNT2 name is too large")
            }
            guard buffer.count >= 76 + nameLength else { return nil }
            let name = Data(buffer.dropFirst(76).prefix(nameLength))
            buffer.removeFirst(76 + nameLength)
            guard error == 0 else {
                return .failure("Could not read directory entry (Android error \(error))")
            }
            return .entry(mode: mode, size: size, modificationTime: modificationTime, name: name)

        case SyncID.done.rawValue:

            guard buffer.count >= 76 else { return nil }
            buffer.removeFirst(76)
            return .done

        case SyncID.fail.rawValue:
            let messageLength = Int(uint32(at: 4))
            guard messageLength <= Int(ADBMessage.maxPayload) else {
                throw ADBError.protocolError("SYNC LIST failure message is too large")
            }
            guard buffer.count >= 8 + messageLength else { return nil }
            let messageData = Data(buffer.dropFirst(8).prefix(messageLength))
            buffer.removeFirst(8 + messageLength)
            return .failure(String(decoding: messageData, as: UTF8.self))

        default:
            throw ADBError.protocolError("Unexpected SYNC LIST response id")
        }
    }

    private func uint32(at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private func uint64(at offset: Int) -> UInt64 {
        buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    private func int64(at offset: Int) -> Int64 {
        Int64(bitPattern: uint64(at: offset))
    }
}
