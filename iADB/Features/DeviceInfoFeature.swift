import ComposableArchitecture
import Foundation

@Reducer
struct DeviceInfoFeature {
    @ObservableState
    struct State: Equatable {
        var details = DeviceDetails()
        var isLoading = false
        var isRebooting = false
        var errorMessage: String?
    }

    enum Action {
        case fetch
        case fetched(Result<DeviceDetails, Error>)
        case reboot(String)
        case rebooted(Result<Void, Error>)
        case cancel
    }

    private enum CancelID { case request }
    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .fetch:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        var details = DeviceDetails()
                        details.model = try await adbClient.getDeviceProperty("ro.product.model")
                        details.manufacturer = try await adbClient.getDeviceProperty("ro.product.manufacturer")
                        details.androidVersion = try await adbClient.getAndroidVersion()
                        details.sdkVersion = try await adbClient.getSDKVersion()
                        details.serialNumber = try await adbClient.getDeviceSerial()
                        details.buildFingerprint = try await adbClient.getDeviceProperty("ro.build.fingerprint")
                        details.cpuAbi = try await adbClient.getDeviceProperty("ro.product.cpu.abi")
                        details.deviceName = try await adbClient.getDeviceProperty("ro.product.device")
                        details.batteryLevel = try await adbClient.getBatteryLevel()
                        await send(.fetched(.success(details)))
                    } catch {
                        await send(.fetched(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .fetched(.success(let details)):
                state.isLoading = false
                state.details = details
                return .none

            case .fetched(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .reboot(let mode):
                state.isRebooting = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        try await adbClient.reboot(mode)
                        await send(.rebooted(.success(())))
                    } catch {
                        await send(.rebooted(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .rebooted(.success):
                state.isRebooting = false
                return .none

            case .rebooted(.failure(let error)):
                state.isRebooting = false
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isLoading = false
                state.isRebooting = false
                return .cancel(id: CancelID.request)
            }
        }
    }
}
