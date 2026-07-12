import Foundation
import Testing
@testable import iADB

struct ADBShellQuoteTests {
    @Test
    func quotesSpacesAndCommandSubstitutionLiterally() {
        #expect(adbShellQuote("My Files/$(reboot).txt") == "'My Files/$(reboot).txt'")
    }

    @Test
    func escapesEmbeddedSingleQuote() {
        #expect(adbShellQuote("O'Brien.txt") == "'O'\\''Brien.txt'")
    }

    @Test
    func quotesEmptyArgument() {
        #expect(adbShellQuote("") == "''")
    }

    @Test
    func screenshotUsesUniqueAppOwnedTemporaryPath() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        #expect(
            ADBClient.screenshotRemotePath(id: id)
                == "/data/local/tmp/iadb-screenshot-00000000-0000-0000-0000-000000000041.png"
        )
    }
}
