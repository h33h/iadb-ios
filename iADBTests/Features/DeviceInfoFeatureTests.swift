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
        }
    }

    @Test
    func rebootSuccess() async {
        var rebootMode: String?
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { mode in rebootMode = mode }
        }

        await store.send(.reboot(mode: "recovery"))
        // Use \.rebootResult (not .success) to work around Swift 6.2 compiler crash
        // in key path IR generation for Result<Void, Error>
        await store.receive(\.rebootResult)
        #expect(rebootMode == "recovery")
    }

    @Test
    func rebootError() async {
        let store = TestStore(initialState: DeviceInfoFeature.State()) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { _ in throw ADBError.notConnected }
        }

        await store.send(.reboot(mode: ""))
        await store.receive(\.rebootResult) {
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
    }
}
