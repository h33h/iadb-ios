import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct DeviceInfoFeatureTests {
    @Test
    func fetchDeviceInfoSuccess() async {
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.getDeviceProperty = { property in
                switch property {
                case "ro.product.model": return "Pixel 7"
                case "ro.product.manufacturer": return "Google"
                case "ro.build.fingerprint": return "google/panther/panther:14"
                case "ro.product.cpu.abi": return "arm64-v8a"
                case "ro.product.device": return "panther"
                default: return ""
                }
            }
            $0.adbClient.getAndroidVersion = { "14" }
            $0.adbClient.getSDKVersion = { "34" }
            $0.adbClient.getDeviceSerial = { "ABC123" }
            $0.adbClient.getBatteryLevel = { "  level: 85" }
            $0.adbClient.shell = { cmd in
                if cmd == "wm size" { return "Physical size: 1080x2400" }
                if cmd == "ip -4 route get 1.1.1.1" {
                    return "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 2000"
                }
                return ""
            }
        }

        await store.send(.fetchDeviceInfo) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.deviceInfoLoaded.success) {
            $0.isLoading = false
            $0.details.model = "Pixel 7"
            $0.details.manufacturer = "Google"
            $0.details.androidVersion = "14"
            $0.details.sdkVersion = "34"
            $0.details.serialNumber = "ABC123"
            $0.details.buildFingerprint = "google/panther/panther:14"
            $0.details.cpuAbi = "arm64-v8a"
            $0.details.deviceName = "panther"
            $0.details.batteryLevel = "85%"
            $0.details.screenResolution = "1080x2400"
            $0.details.ipAddress = "192.168.1.42"
        }
    }

    @Test
    func fetchDeviceInfoError() async {
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.getDeviceProperty = { _ in throw ADBError.notConnected }
        }

        await store.send(.fetchDeviceInfo) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.deviceInfoLoaded.failure) {
            $0.isLoading = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
            $0.errorRecovery = .fetch
        }
    }

    @Test
    func rebootSuccess() async {
        let rebootMode = LockIsolated<String?>(nil)
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { mode in rebootMode.setValue(mode) }
        }

        await store.send(.reboot(mode: "recovery")) {
            $0.isRebooting = true
            $0.activeRebootMode = "recovery"
        }
        // Use \.rebootResult (not .success) to work around Swift 6.2 compiler crash
        // in key path IR generation for Result<Void, Error>
        await store.receive(\.rebootResult) {
            $0.isRebooting = false
            $0.activeRebootMode = nil
            $0.rebootStatusMessage = "Reboot command sent. Waiting for the device to come back online…"
        }
        #expect(rebootMode.value == "recovery")
    }

    @Test
    func rebootError() async {
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { _ in throw ADBError.notConnected }
        }

        await store.send(.reboot(mode: "")) {
            $0.isRebooting = true
            $0.activeRebootMode = ""
        }
        await store.receive(\.rebootResult) {
            $0.isRebooting = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
            $0.errorRecovery = .reboot("")
            $0.activeRebootMode = nil
        }
    }

    @Test
    func sourceIPAddressUsesSrcInsteadOfGateway() {
        let output = "1.1.1.1 via 192.168.50.1 dev wlan0 src 192.168.50.27 uid 2000"
        #expect(DeviceInfoFeature.sourceIPAddress(from: output) == "192.168.50.27")
        #expect(DeviceInfoFeature.sourceIPAddress(from: "default via 192.168.50.1 dev wlan0") == nil)
    }
}
