import Foundation
import Testing
@testable import ADBCore

@Suite("Маршрутизация потоков")
struct StreamStateTests {
    @Test("Таймаут чтения не забирает следующий пакет")
    func timeoutLeavesNextPacketAvailable() async throws {
        let inbox = ADBStreamInbox()
        do {
            _ = try await inbox.next(timeout: 0.01)
            Issue.record("Чтение не завершилось по таймауту")
        } catch ADBError.timeout {
        }

        let expected = ADBMessage.writeMessage(localId: 17, remoteId: 1, data: Data("later".utf8))
        await inbox.push(expected)
        let received = try await inbox.next(timeout: 0.1)
        #expect(received.data == expected.data)
    }

    @Test("Отменённое чтение не забирает следующий пакет")
    func cancellationLeavesNextPacketAvailable() async throws {
        let inbox = ADBStreamInbox()
        let pending = Task { try await inbox.next() }
        await Task.yield()
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Отменённое чтение вернуло пакет")
        } catch is CancellationError {
        }

        await inbox.push(.writeMessage(localId: 18, remoteId: 1, data: Data("kept".utf8)))
        let next = try await inbox.next(timeout: 0.1)
        #expect(next.data == Data("kept".utf8))
    }

    @Test("Пакеты двух потоков не перемешиваются")
    func routerDeliversPacketsToMatchingInbox() async throws {
        let transport = ScriptedTransport()
        try await transport.connect(host: "192.0.2.1", port: 5555, timeout: 1)
        let router = ADBMessageRouter(transport: transport)
        let first = try await router.register(localId: 1)
        let second = try await router.register(localId: 2)

        await transport.enqueue(.writeMessage(localId: 102, remoteId: 2, data: Data("two".utf8)))
        await transport.enqueue(.writeMessage(localId: 101, remoteId: 1, data: Data("one".utf8)))

        let firstPacket = try await first.next(timeout: 0.5)
        let secondPacket = try await second.next(timeout: 0.5)
        #expect(firstPacket.data == Data("one".utf8))
        #expect(secondPacket.data == Data("two".utf8))
        await router.shutdown()
        transport.disconnect()
    }
}
