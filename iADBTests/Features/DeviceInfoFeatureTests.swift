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
            $0.fetchGeneration = 1
            $0.activeFetchGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.deviceInfoLoaded) {
            $0.isLoading = false
            $0.activeFetchGeneration = nil
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
            $0.fetchGeneration = 1
            $0.activeFetchGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.deviceInfoLoaded) {
            $0.isLoading = false
            $0.activeFetchGeneration = nil
            $0.errorMessage = ADBError.notConnected.localizedDescription
            $0.errorRecovery = .fetch
        }
    }

    @Test
    func rebootSuccess() async {
        let rebootMode = LockIsolated<String?>(nil)
        let target = Self.connectedTarget()
        let store = TestStore(initialState: DeviceInfoFeature.State(remoteTarget: target)) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { mode in rebootMode.setValue(mode) }
        }

        await store.send(.reboot(
            mode: "recovery",
            confirmation: target.confirmation(for: "reboot:recovery")
        )) {
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
        let target = Self.connectedTarget()
        let store = TestStore(initialState: DeviceInfoFeature.State(remoteTarget: target)) {
            DeviceInfoFeature()
        } withDependencies: {
            $0.adbClient.reboot = { _ in throw ADBError.notConnected }
        }

        await store.send(.reboot(
            mode: "",
            confirmation: target.confirmation(for: "reboot:")
        )) {
            $0.isRebooting = true
            $0.activeRebootMode = ""
        }
        await store.receive(\.rebootResult) {
            $0.isRebooting = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
            $0.activeRebootMode = nil
        }
    }

    private static func connectedTarget() -> RemoteDeviceTarget {
        RemoteDeviceTarget(
            deviceID: "serial:test-device",
            deviceName: "Pixel Test",
            transportGeneration: 1,
            switchedAt: Date(timeIntervalSince1970: 1),
            isConnected: true
        )
    }

    @Test
    func staleFetchAndRebootConfirmationAreRejected() async {
        var currentTarget = Self.connectedTarget()
        let staleConfirmation = currentTarget.confirmation(for: "reboot:recovery")
        currentTarget.transportGeneration = 2
        var existing = DeviceDetails()
        existing.model = "Current"
        let store = TestStore(initialState: DeviceInfoFeature.State(
            remoteTarget: currentTarget,
            details: existing,
            isLoading: true,
            fetchGeneration: 2,
            activeFetchGeneration: 2
        )) {
            DeviceInfoFeature()
        }

        var stale = DeviceDetails()
        stale.model = "Stale"
        await store.send(.deviceInfoLoaded(generation: 1, .success(stale)))
        #expect(store.state.details.model == "Current")

        await store.send(.deviceInfoLoaded(generation: 2, .success(existing))) {
            $0.isLoading = false
            $0.activeFetchGeneration = nil
        }
        await store.send(.reboot(
            mode: "recovery",
            confirmation: staleConfirmation
        )) {
            $0.errorMessage = "The target device changed. Confirm Reboot again on the connected device."
        }
        #expect(!store.state.isRebooting)
    }

    @Test
    func sourceIPAddressUsesSrcInsteadOfGateway() {
        let output = "1.1.1.1 via 192.168.50.1 dev wlan0 src 192.168.50.27 uid 2000"
        #expect(DeviceInfoFeature.sourceIPAddress(from: output) == "192.168.50.27")
        #expect(DeviceInfoFeature.sourceIPAddress(from: "default via 192.168.50.1 dev wlan0") == nil)
    }

    @Test
    func storageValuesUseDataFilesystemKilobytes() {
        let output = """
        Filesystem     1K-blocks     Used Available Use% Mounted on
        /dev/block/dm-5  250000000 70000000 180000000  29% /data
        """

        let values = DeviceInfoFeature.storageValues(from: output)
        #expect(values?.total == "256 GB")
        #expect(values?.available.contains("184") == true)
        #expect(values?.available.hasSuffix("GB") == true)
        #expect(DeviceInfoFeature.storageValues(from: "unavailable") == nil)
    }
}
