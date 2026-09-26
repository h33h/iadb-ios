import Foundation
import Network
import Testing
@testable import ADBCore

@Suite("Обнаружение устройств")
struct DiscoveryTests {
    @Test("Остановка завершает поток событий")
    func stoppingFinishesEventStream() async throws {
        let discovery = ADBDeviceDiscovery()
        let stream = discovery.start()
        let finished = CompletionFlag()
        let reader = Task {
            for await _ in stream {}
            await finished.mark()
        }

        discovery.stop()

        let completed = await finished.waitForCompletion()
        #expect(completed)
        reader.cancel()
    }

    @Test("QR-имя совпадает только с конкретной службой")
    func qrServiceNameMustMatchExactly() {
        #expect(ADBServiceBrowser.matchesServiceName("pixel", target: "pixel._adb-tls-pairing._tcp."))
        #expect(!ADBServiceBrowser.matchesServiceName("pixel-2", target: "pixel"))
    }

    @Test("Поиск сопряжения разрешает объявленную TCP-службу")
    func pairingBrowserResolvesAdvertisedTCPService() async throws {
        let serviceName = "iadb-browser-\(UUID().uuidString)"
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "com.iadb.tests.pairing-browser")
        listener.service = NWListener.Service(
            name: serviceName,
            type: "_adb-tls-pairing._tcp",
            domain: "local."
        )
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var listenerReady = false
        for _ in 0..<100 {
            if case .ready = listener.state {
                listenerReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(listenerReady)
        let expectedPort = try #require(listener.port?.rawValue)

        let endpoint = try await ADBServiceBrowser().discoverPairingService(
            serviceName: serviceName,
            timeout: 5
        )
        #expect(endpoint.port == expectedPort)
        #expect(!endpoint.host.isEmpty)
    }
}

private actor CompletionFlag {
    private var completed = false

    func mark() { completed = true }

    func waitForCompletion() async -> Bool {
        for _ in 0..<100 {
            if completed { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return completed
    }
}
