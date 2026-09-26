import ADBCore
import Testing

@Suite("Публичный API")
struct PublicSurfaceTests {
    @Test("Аргумент shell не выполняет подстановку команд")
    func shellArgumentIsQuotedLiterally() {
        #expect(ADBClient.shellQuote("a'b$(reboot)") == "'a'\\''b$(reboot)'")
    }

    @Test("Приложение может прочитать QR-код сопряжения через публичный API")
    func pairingQRIsAvailableToApplication() throws {
        let parsed = try #require(ADBPairing.parseQRCode("WIFI:T:ADB;S:pixel;P:secret;;"))
        #expect(parsed.serviceName == "pixel")
        #expect(parsed.password == "secret")
    }
}
