import Foundation
import Testing
@testable import ADBCore

@Suite("ADB-клиент")
struct ClientIntegrationTests {
    private func connectedClient(maxData: UInt32 = 65_536) async throws -> (ADBClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        await transport.enqueue(
            ADBMessage(
                command: .connect,
                arg0: ADBMessage.version,
                arg1: maxData,
                data: Data("device::features=shell_v2\0".utf8)
            )
        )
        try await client.connect(host: "192.0.2.1")
        return (client, transport)
    }

    @Test("Подключение сохраняет согласованный баннер и размер пакета")
    func connectNegotiatesDeviceMetadata() async throws {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        await transport.enqueue(
            ADBMessage(
                command: .connect,
                arg0: ADBMessage.version,
                arg1: 32_768,
                data: Data("device::features=shell_v2\0".utf8)
            )
        )

        try await client.connect(host: "192.0.2.1")

        #expect(client.isConnected)
        #expect(client.maxData == 32_768)
        #expect(client.deviceBanner == "device::features=shell_v2")
        let handshake = try #require(transport.sentMessages.first)
        #expect(handshake.commandType == .connect)
        #expect(handshake.arg0 == ADBMessage.version)
        #expect(handshake.dataString?.hasPrefix("host::") == true)
        await client.disconnect()
    }

    @Test("Ошибочный ответ рукопожатия закрывает транспорт")
    func invalidHandshakeDisconnects() async {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        await transport.enqueue(.writeMessage(localId: 1, remoteId: 1, data: Data()))

        do {
            try await client.connect(host: "192.0.2.1")
            Issue.record("Некорректное рукопожатие принято")
        } catch ADBError.protocolError {
            #expect(!client.isConnected)
            #expect(client.deviceBanner.isEmpty)
        } catch {
            Issue.record("Получена другая ошибка: \(error)")
        }
    }

    @Test("AUTH отправляет подпись токена до CNXN")
    func authChallengeUsesSigningIdentity() async throws {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        let challenge = Data(0..<20)
        await transport.enqueue(ADBMessage(
            command: .auth,
            arg0: ADBAuthType.token.rawValue,
            arg1: 0,
            data: challenge
        ))
        await transport.enqueue(ADBMessage(
            command: .connect,
            arg0: ADBMessage.version,
            arg1: 4_096,
            data: Data("device::\0".utf8)
        ))

        try await client.connect(host: "192.0.2.1")

        let signature = try #require(transport.sentMessages.first { $0.commandType == .auth })
        #expect(signature.arg0 == ADBAuthType.signature.rawValue)
        #expect(signature.data == Data(challenge.reversed()))
        await client.disconnect()
    }

    @Test("После STLS клиент обновляет транспорт до TLS")
    func stlsUpgradePrecedesAuthenticatedConnect() async throws {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        await transport.enqueue(.stlsMessage())
        await transport.enqueue(ADBMessage(
            command: .connect,
            arg0: ADBMessage.version,
            arg1: 8_192,
            data: Data("device::\0".utf8)
        ))

        try await client.connect(host: "192.0.2.1")

        #expect(transport.upgradeCount == 1)
        #expect(transport.sentMessages.map(\.commandType).prefix(2).elementsEqual([.connect, .stls]))
        #expect(transport.events.prefix(5).elementsEqual([
            .sent(.connect),
            .received(.stls),
            .sent(.stls),
            .tlsUpgrade,
            .received(.connect),
        ]))
        #expect(client.maxData == 8_192)
        await client.disconnect()
    }

    @Test("Ошибка TLS-апгрейда закрывает соединение")
    func failedSTLSUpgradeDisconnects() async {
        let transport = ScriptedTransport(failTLSUpgrade: true)
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        await transport.enqueue(.stlsMessage())

        do {
            try await client.connect(host: "192.0.2.1")
            Issue.record("Соединение принято после ошибки TLS")
        } catch ADBError.connectionFailed {
            #expect(!client.isConnected)
        } catch {
            Issue.record("Получена другая ошибка: \(error)")
        }
    }

    @Test("Повторный AUTH отправляет открытый ключ хоста")
    func authFallbackSendsPublicKey() async throws {
        let transport = ScriptedTransport()
        let client = ADBClient(transport: transport, identity: InMemoryIdentity())
        let token = Data((0..<20).map(UInt8.init))
        for _ in 0..<2 {
            await transport.enqueue(ADBMessage(
                command: .auth,
                arg0: ADBAuthType.token.rawValue,
                arg1: 0,
                data: token
            ))
        }
        await transport.enqueue(ADBMessage(
            command: .connect,
            arg0: ADBMessage.version,
            arg1: 4_096,
            data: Data("device::\0".utf8)
        ))

        try await client.connect(host: "192.0.2.1")

        let responses = transport.sentMessages.filter { $0.commandType == .auth }
        #expect(responses.count == 2)
        #expect(responses.first?.arg0 == ADBAuthType.signature.rawValue)
        #expect(responses.last?.arg0 == ADBAuthType.rsaPublic.rawValue)
        #expect(responses.last?.data == Data("test-key\0".utf8))
        await client.disconnect()
    }

    @Test("Открытие службы прекращается по таймауту")
    func openStreamHasDeadline() async throws {
        let (client, _) = try await connectedClient()

        do {
            _ = try await client.openStream(destination: "sync:", timeout: 0.02)
            Issue.record("Поток открылся без ответа устройства")
        } catch ADBError.timeout {
        }
        await client.disconnect()
    }

    @Test("Shell v2 сохраняет порядок stdout, stderr и кода выхода")
    func shellEventsRemainOrdered() async throws {
        let (client, transport) = try await connectedClient()
        await transport.enqueue(.readyMessage(localId: 71, remoteId: 1))
        let events = try await client.openShellCommand("echo hello")
        let payload = shellPacket(id: 1, payload: Data("hello".utf8))
            + shellPacket(id: 2, payload: Data("warning".utf8))
            + shellPacket(id: 3, payload: Data([0]))
        await transport.enqueue(.writeMessage(localId: 71, remoteId: 1, data: payload))

        var received: [ShellEvent] = []
        for try await event in events { received.append(event) }

        #expect(received == [
            .stdout(Data("hello".utf8)),
            .stderr(Data("warning".utf8)),
            .exit(0),
        ])
        #expect(transport.sentMessages.contains { $0.commandType == .ready && $0.arg0 == 1 && $0.arg1 == 71 })
        await client.disconnect()
    }

    @Test("Разрыв до принятия reboot не считается успехом")
    func rebootBeforeAcceptedStreamFails() async throws {
        let (client, transport) = try await connectedClient()
        let operation = Task { try await client.reboot() }
        _ = try await waitForOpen("shell,v2,raw:reboot", on: transport)
        transport.disconnect()

        do {
            try await operation.value
            Issue.record("reboot сообщил об успехе до принятия команды")
        } catch ADBError.connectionClosed {
        }
    }

    @Test("SYNC делит большой блок по согласованному пределу ADB")
    func pushRespectsNegotiatedPacketSize() async throws {
        let (client, transport) = try await connectedClient(maxData: 4_096)
        await transport.enqueue(.readyMessage(localId: 81, remoteId: 1))
        for _ in 0..<19 {
            await transport.enqueue(.readyMessage(localId: 81, remoteId: 1))
        }
        await transport.enqueue(
            .writeMessage(localId: 81, remoteId: 1, data: syncFrame("OKAY", value: 0))
        )

        try await client.pushData(Data(repeating: 0xCD, count: 65_536), to: "/data/local/tmp/a")

        let writes = transport.sentMessages.filter { $0.commandType == .write }
        #expect(writes.count == 19)
        #expect(writes.allSatisfy { $0.data.count <= 4_096 })
        let bytes = writes.reduce(into: Data()) { $0.append($1.data) }
        let sendLength = Int(syncValue(bytes))
        let dataOffset = 8 + sendLength
        #expect(syncTag(Data(bytes.dropFirst(dataOffset))) == "DATA")
        #expect(syncValue(Data(bytes.dropFirst(dataOffset))) == 65_536)
        #expect(syncTag(Data(bytes.dropFirst(dataOffset + 8 + 65_536))) == "DONE")
        await client.disconnect()
    }

    @Test("Ответ SYNC до транспортного OKAY не теряется")
    func earlyServiceResponseIsPreserved() async throws {
        let (client, transport) = try await connectedClient()
        await transport.enqueue(.readyMessage(localId: 82, remoteId: 1))
        await transport.enqueue(
            .writeMessage(localId: 82, remoteId: 1, data: syncFrame("OKAY", value: 0))
        )
        for _ in 0..<3 {
            await transport.enqueue(.readyMessage(localId: 82, remoteId: 1))
        }

        try await client.pushData(Data([0xAB]), to: "/data/local/tmp/a")

        #expect(transport.sentMessages.contains {
            $0.commandType == .ready && $0.arg0 == 1 && $0.arg1 == 82
        })
        await client.disconnect()
    }

    @Test("SYNC собирает ответ из нескольких пакетов ADB")
    func pullReassemblesSplitServiceFrames() async throws {
        let (client, transport) = try await connectedClient()
        await transport.enqueue(.readyMessage(localId: 83, remoteId: 1))
        await transport.enqueue(.readyMessage(localId: 83, remoteId: 1))
        let service = syncFrame("DATA", value: 5, payload: Data("hello".utf8))
            + syncFrame("DONE", value: 0)
        await transport.enqueue(
            .writeMessage(localId: 83, remoteId: 1, data: Data(service.prefix(3)))
        )
        await transport.enqueue(
            .writeMessage(localId: 83, remoteId: 1, data: Data(service.dropFirst(3)))
        )

        let bytes = try await client.pullFile(remotePath: "/sdcard/test.txt")

        #expect(bytes == Data("hello".utf8))
        #expect(transport.sentMessages.filter { $0.commandType == .ready }.count == 2)
        await client.disconnect()
    }

    @Test("LIST_V2 сохраняет имя и числовые метаданные файла")
    func listDirectoryPreservesBinaryMetadata() async throws {
        let (client, transport) = try await connectedClient()
        let path = "/sdcard"
        let size: UInt64 = 5_000_000_042
        await transport.enqueue(.readyMessage(localId: 84, remoteId: 1))
        await transport.enqueue(.readyMessage(localId: 84, remoteId: 1))
        await transport.enqueue(
            .writeMessage(localId: 84, remoteId: 1, data: syncStat(mode: 0o040755))
        )

        let listing = Task { try await client.listDirectoryEntries(path) }
        _ = try await waitForOpen(
            "shell,v2,raw:test -r '/sdcard' && test -x '/sdcard' || exit 13",
            on: transport
        )
        await transport.enqueue(.readyMessage(localId: 184, remoteId: 2))
        await transport.enqueue(
            .writeMessage(localId: 184, remoteId: 2, data: shellPacket(id: 3, payload: Data([0])))
        )
        try await waitForSyncWrite("LIS2", on: transport)
        await transport.enqueue(.readyMessage(localId: 84, remoteId: 1))
        await transport.enqueue(.writeMessage(
            localId: 84,
            remoteId: 1,
            data: syncDirectoryEntry(
                name: Data("line\nbreak.txt".utf8),
                mode: 0o100644,
                size: size,
                modificationTime: 1_700_000_000
            ) + Data("DONE".utf8) + Data(repeating: 0, count: 72)
        ))

        let entries = try await listing.value
        let entry = try #require(entries.only)
        #expect(entry.name == "line\nbreak.txt")
        #expect(entry.fullPath == "/sdcard/line\nbreak.txt")
        #expect(entry.mode == 0o100644)
        #expect(entry.size == size)
        #expect(entry.modificationDate == Date(timeIntervalSince1970: 1_700_000_000))
        await client.disconnect()
    }
}
