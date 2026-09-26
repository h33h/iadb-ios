import Foundation
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
