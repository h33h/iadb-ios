import Testing
@testable import iADB

struct LocalizedDecimalInputTests {
    @Test
    func localizedPortsNormalizeToUInt16() {
        #expect(LocalizedDecimalInput.positiveUInt16("٣٧٠٠٠") == 37000)
        #expect(LocalizedDecimalInput.positiveUInt16("３７０００") == 37000)
    }

    @Test
    func invalidPortsAreRejected() {
        #expect(LocalizedDecimalInput.positiveUInt16("0") == nil)
        #expect(LocalizedDecimalInput.positiveUInt16("65536") == nil)
        #expect(LocalizedDecimalInput.positiveUInt16("ⅠⅡⅢ") == nil)
        #expect(LocalizedDecimalInput.positiveUInt16("37a00") == nil)
    }
}
