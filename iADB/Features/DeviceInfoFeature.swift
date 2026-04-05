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

                    await send(.deviceInfoLoaded(.success(details)))
                } catch: { error, send in
                    await send(.deviceInfoLoaded(.failure(error)))
                }

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
