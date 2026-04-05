import Foundation
import XCTest
@testable import iADB

final class DeviceInfoTests: XCTestCase {

    // MARK: - SavedDevice

    func testSavedDeviceInit() {
        let device = SavedDevice(name: "My Phone", host: "192.168.1.100", port: 5555)
        XCTAssertEqual(device.name, "My Phone")
        XCTAssertEqual(device.host, "192.168.1.100")
        XCTAssertEqual(device.port, 5555)
        XCTAssertNotNil(device.id)
    }

    func testSavedDeviceDefaultPort() {
        let device = SavedDevice(host: "10.0.0.1")
        XCTAssertEqual(device.port, 5555)
    }

    func testSavedDeviceDefaultName() {
        let device = SavedDevice(host: "10.0.0.1")
        XCTAssertEqual(device.name, "")
    }

    func testDisplayNameWithName() {
        let device = SavedDevice(name: "Pixel 7", host: "192.168.1.1", port: 5555)
        XCTAssertEqual(device.displayName, "Pixel 7")
    }

    func testDisplayNameWithoutName() {
        let device = SavedDevice(name: "", host: "192.168.1.1", port: 5555)
        XCTAssertEqual(device.displayName, "192.168.1.1:5555")
    }

    func testAddress() {
        let device = SavedDevice(host: "10.0.0.5", port: 5556)
        XCTAssertEqual(device.address, "10.0.0.5:5556")
    }

    func testSavedDeviceCodable() throws {
        let device = SavedDevice(name: "Test", host: "192.168.0.1", port: 5555)
        let encoded = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(SavedDevice.self, from: encoded)
        XCTAssertEqual(decoded.id, device.id)
        XCTAssertEqual(decoded.name, device.name)
        XCTAssertEqual(decoded.host, device.host)
        XCTAssertEqual(decoded.port, device.port)
    }

    func testSavedDeviceHashable() {
        let d1 = SavedDevice(name: "A", host: "1.1.1.1")
        let d2 = SavedDevice(name: "B", host: "2.2.2.2")
        let set: Set<SavedDevice> = [d1, d2, d1]
        XCTAssertEqual(set.count, 2)
    }

    func testSavedDeviceArrayCodable() throws {
        let devices = [
            SavedDevice(name: "A", host: "1.1.1.1"),
            SavedDevice(name: "B", host: "2.2.2.2", port: 5556)
        ]
        let data = try JSONEncoder().encode(devices)
        let decoded = try JSONDecoder().decode([SavedDevice].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].host, "1.1.1.1")
        XCTAssertEqual(decoded[1].port, 5556)
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

    // MARK: - ConnectionState

    func testConnectionStateStatusText() {
        XCTAssertEqual(ConnectionState.disconnected.statusText, "Disconnected")
        XCTAssertEqual(ConnectionState.connecting.statusText, "Connecting...")
        XCTAssertEqual(ConnectionState.authenticating.statusText, "Waiting for device authorization...")
        XCTAssertEqual(ConnectionState.connected.statusText, "Connected")
        XCTAssertEqual(ConnectionState.error("fail").statusText, "Error: fail")
    }

    func testConnectionStateIsConnected() {
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isConnected)
        XCTAssertFalse(ConnectionState.authenticating.isConnected)
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
