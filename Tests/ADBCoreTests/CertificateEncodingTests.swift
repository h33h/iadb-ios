import Foundation
import Testing
@testable import ADBCore

@Suite("Время сертификата")
struct CertificateEncodingTests {
    @Test("Дата до 2050 года кодируется как UTCTime")
    func earlierDateUsesUTCTime() throws {
        let date = try makeUTCDate(year: 2049)
        let encoded = ADBCrypto.derCertificateTime(date)

        #expect(encoded.first == 0x17)
        #expect(String(decoding: encoded.dropFirst(2), as: UTF8.self) == "491231235959Z")
    }

    @Test("Дата с 2050 года кодируется как GeneralizedTime")
    func laterDateUsesGeneralizedTime() throws {
        let date = try makeUTCDate(year: 2050)
        let encoded = ADBCrypto.derCertificateTime(date)

        #expect(encoded.first == 0x18)
        #expect(String(decoding: encoded.dropFirst(2), as: UTF8.self) == "20501231235959Z")
    }

    private func makeUTCDate(year: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(calendar.date(from: DateComponents(
            year: year,
            month: 12,
            day: 31,
            hour: 23,
            minute: 59,
            second: 59
        )))
    }
}
