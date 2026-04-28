import Foundation
import XCTest
@testable import iADB

final class DeviceInfoTests: XCTestCase {

    // MARK: - PairedDevice

    func testPairedDeviceInit() {
        let key = Data([1, 2, 3])
        let device = PairedDevice(name: "Pixel 7", publicKey: key, lastHost: "192.168.1.42")
        XCTAssertEqual(device.name, "Pixel 7")
        XCTAssertEqual(device.publicKey, key)
        XCTAssertEqual(device.lastHost, "192.168.1.42")
        XCTAssertNotNil(device.id)
    }

    func testPairedDeviceDisplayName() {
        let d1 = PairedDevice(name: "Pixel", publicKey: Data(), lastHost: "10.0.0.1")
        XCTAssertEqual(d1.displayName, "Pixel")
        let d2 = PairedDevice(name: "", publicKey: Data(), lastHost: "10.0.0.1")
        XCTAssertEqual(d2.displayName, "10.0.0.1")
    }

    func testPairedDeviceCodable() throws {
        let device = PairedDevice(name: "Test", publicKey: Data([0xAB, 0xCD]), lastHost: "1.2.3.4")
        let encoded = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(PairedDevice.self, from: encoded)
        XCTAssertEqual(decoded.id, device.id)
        XCTAssertEqual(decoded.name, device.name)
        XCTAssertEqual(decoded.publicKey, device.publicKey)
        XCTAssertEqual(decoded.lastHost, device.lastHost)
    }

    // MARK: - DeviceDetails

    func testDeviceDetailsDefaultValues() {
        let details = DeviceDetails()
        XCTAssertEqual(details.model, "")
        XCTAssertEqual(details.manufacturer, "")
        XCTAssertEqual(details.androidVersion, "")
        XCTAssertEqual(details.sdkVersion, "")
        XCTAssertEqual(details.serialNumber, "")
        XCTAssertEqual(details.batteryLevel, "")
        XCTAssertEqual(details.screenResolution, "")
        XCTAssertEqual(details.cpuAbi, "")
        XCTAssertEqual(details.deviceName, "")
    }

    func testDisplayTitleWithModel() {
        var details = DeviceDetails()
        details.model = "Pixel 7 Pro"
        XCTAssertEqual(details.displayTitle, "Pixel 7 Pro")
    }

    func testDisplayTitleWithoutModel() {
        let details = DeviceDetails()
        XCTAssertEqual(details.displayTitle, "Android Device")
    }

    func testSnapshotTextIncludesOnlyAvailableFields() {
        var details = DeviceDetails()
        details.model = "Pixel 9"
        details.androidVersion = "15"
        details.batteryLevel = "82%"
        details.ipAddress = "192.168.1.10"

        let snapshot = details.snapshotText

        XCTAssertTrue(snapshot.contains("## Identity"))
        XCTAssertTrue(snapshot.contains("Model: Pixel 9"))
        XCTAssertTrue(snapshot.contains("## System"))
        XCTAssertTrue(snapshot.contains("Android Version: 15"))
        XCTAssertTrue(snapshot.contains("## Hardware"))
        XCTAssertTrue(snapshot.contains("Battery Level: 82%"))
        XCTAssertTrue(snapshot.contains("## Network"))
        XCTAssertTrue(snapshot.contains("IP Address: 192.168.1.10"))
        XCTAssertFalse(snapshot.contains("Manufacturer:"))
    }

    // MARK: - ConnectionState

    func testConnectionStateStatusText() {
        XCTAssertEqual(ConnectionState.disconnected.statusText, "Disconnected")
        XCTAssertEqual(ConnectionState.connecting.statusText, "Connecting...")
        XCTAssertEqual(ConnectionState.connected.statusText, "Connected")
        XCTAssertEqual(ConnectionState.error("fail").statusText, "Error: fail")
    }

    func testConnectionStateIsConnected() {
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isConnected)
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.error("x").isConnected)
    }

    func testConnectionStateEquatable() {
        XCTAssertEqual(ConnectionState.disconnected, ConnectionState.disconnected)
        XCTAssertEqual(ConnectionState.connected, ConnectionState.connected)
        XCTAssertEqual(ConnectionState.error("a"), ConnectionState.error("a"))
        XCTAssertNotEqual(ConnectionState.error("a"), ConnectionState.error("b"))
        XCTAssertNotEqual(ConnectionState.connecting, ConnectionState.connected)
    }
}
