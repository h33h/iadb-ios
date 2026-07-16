import Foundation
import XCTest
@testable import iADB

final class DeviceInfoTests: XCTestCase {
    func testPairedDeviceRoundTrip() throws {
        let device = PairedDevice(
            name: "Pixel",
            guid: "device-guid",
            lastHost: "192.168.1.42",
            lastPort: 37141
        )

        let decoded = try JSONDecoder().decode(
            PairedDevice.self,
            from: JSONEncoder().encode(device)
        )

        XCTAssertEqual(decoded, device)
    }

    func testDeviceIdentityPrefersPairedGUID() {
        let discovered = DiscoveredDevice(
            id: "service",
            name: "Android",
            host: "192.168.1.42",
            port: 37141,
            isPaired: true
        )
        let paired = PairedDevice(
            name: "Pixel",
            guid: "device-guid",
            lastHost: discovered.host,
            lastPort: discovered.port
        )

        XCTAssertEqual(
            DeviceIdentity.resolved(from: discovered, pairedDevices: [paired]).stableID,
            "guid:device-guid"
        )
    }
}
