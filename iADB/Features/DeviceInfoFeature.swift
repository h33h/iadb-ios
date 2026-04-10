import Foundation
import ComposableArchitecture

@Reducer
struct DeviceInfoFeature {
    @ObservableState
    struct State: Equatable {
        var details = DeviceDetails()
        var isLoading = false
        var errorMessage: String?
    }

    enum Action {
        case fetchDeviceInfo
        case deviceInfoLoaded(Result<DeviceDetails, Error>)
        case reboot(mode: String)
        case rebootResult(Result<Void, Error>)
    }

    private enum CancelID { case fetchInfo, reboot }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .fetchDeviceInfo:
                state.isLoading = true
                state.errorMessage = nil

                return .run { send in
                    var details = DeviceDetails()
                    details.model = try await adbClient.getDeviceProperty("ro.product.model")
                    details.manufacturer = try await adbClient.getDeviceProperty("ro.product.manufacturer")
                    details.androidVersion = try await adbClient.getAndroidVersion()
                    details.sdkVersion = try await adbClient.getSDKVersion()
                    details.serialNumber = try await adbClient.getDeviceSerial()
                    details.buildFingerprint = try await adbClient.getDeviceProperty("ro.build.fingerprint")
                    details.cpuAbi = try await adbClient.getDeviceProperty("ro.product.cpu.abi")
                    details.deviceName = try await adbClient.getDeviceProperty("ro.product.device")

                    let batteryOutput = try await adbClient.getBatteryLevel()
                    if let levelRange = batteryOutput.range(of: "\\d+", options: .regularExpression) {
                        details.batteryLevel = String(batteryOutput[levelRange]) + "%"
                    }

                    let resOutput = try await adbClient.shell("wm size")
                    if let sizeRange = resOutput.range(of: "\\d+x\\d+", options: .regularExpression) {
                        details.screenResolution = String(resOutput[sizeRange])
                    }

                    if let ipOutput = try? await adbClient.shell("ip route show dev wlan0"),
                       let ipRange = ipOutput.range(of: "\\d+\\.\\d+\\.\\d+\\.\\d+\\s+dev", options: .regularExpression) {
                        let segment = ipOutput[ipRange]
                        if let addrRange = segment.range(of: "\\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
                            details.ipAddress = String(segment[addrRange])
                        }
                    }

                    if let memOutput = try? await adbClient.shell("cat /proc/meminfo") {
                        if let totalRange = memOutput.range(of: "MemTotal:\\s+\\d+", options: .regularExpression) {
                            let digits = memOutput[totalRange].filter { $0.isNumber }
                            if let totalKB = Int(digits) {
                                details.totalMemory = String(format: "%.1f GB", Double(totalKB) / 1_048_576.0)
                            }
                        }
                        if let availRange = memOutput.range(of: "MemAvailable:\\s+\\d+", options: .regularExpression) {
                            let digits = memOutput[availRange].filter { $0.isNumber }
                            if let availKB = Int(digits) {
                                details.availableMemory = String(format: "%.1f GB", Double(availKB) / 1_048_576.0)
                            }
                        }
                    }

                    if let statusOutput = try? await adbClient.shell("dumpsys battery | grep status"),
                       let statusRange = statusOutput.range(of: "\\d+", options: .regularExpression) {
                        let code = Int(statusOutput[statusRange]) ?? 0
                        switch code {
                        case 2: details.batteryStatus = "Charging"
                        case 3: details.batteryStatus = "Discharging"
                        case 4: details.batteryStatus = "Not charging"
                        case 5: details.batteryStatus = "Full"
                        default: details.batteryStatus = "Unknown"
                        }
                    }

                    await send(.deviceInfoLoaded(.success(details)))
                } catch: { error, send in
                    await send(.deviceInfoLoaded(.failure(error)))
                }
                .cancellable(id: CancelID.fetchInfo, cancelInFlight: true)

            case .deviceInfoLoaded(.success(let details)):
                state.isLoading = false
                state.details = details
                return .none

            case .deviceInfoLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .reboot(let mode):
                return .run { send in
                    try await adbClient.reboot(mode)
                    await send(.rebootResult(.success(())))
                } catch: { error, send in
                    await send(.rebootResult(.failure(error)))
                }

            case .rebootResult(.success):
                return .none

            case .rebootResult(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}
