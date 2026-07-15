import Foundation
import ComposableArchitecture

@Reducer
struct DeviceInfoFeature {
    enum ErrorRecovery: Equatable {
        case fetch
    }

    @ObservableState
    struct State: Equatable {
        var remoteTarget = RemoteDeviceTarget.unavailable
        var details = DeviceDetails()
        var isLoading = false
        var fetchGeneration = 0
        var activeFetchGeneration: Int?
        var isRebooting = false
        var errorMessage: String?
        var rebootStatusMessage: String?
        var errorRecovery: ErrorRecovery?
        var activeRebootMode: String?
    }

    enum Action {
        case fetchDeviceInfo
        case deviceInfoLoaded(generation: Int, Result<DeviceDetails, Error>)
        case reboot(mode: String, confirmation: DestructiveActionConfirmation?)
        case rebootResult(Result<Void, Error>)
        case retryError
        case dismissError
        case cancelAll
    }

    private enum CancelID { case fetchInfo, reboot }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .fetchDeviceInfo:
                state.isLoading = true
                state.fetchGeneration += 1
                let generation = state.fetchGeneration
                state.activeFetchGeneration = generation
                state.errorMessage = nil
                state.errorRecovery = nil

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

                    if let ipOutput = try? await adbClient.shell("ip -4 route get 1.1.1.1") {
                        details.ipAddress = Self.sourceIPAddress(from: ipOutput) ?? ""
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

                    if let storageOutput = try? await adbClient.shell("df -k /data"),
                       let storage = Self.storageValues(from: storageOutput) {
                        details.totalStorage = storage.total
                        details.availableStorage = storage.available
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

                    await send(.deviceInfoLoaded(generation: generation, .success(details)))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.deviceInfoLoaded(generation: generation, .failure(error)))
                }
                .cancellable(id: CancelID.fetchInfo, cancelInFlight: true)

            case .deviceInfoLoaded(let generation, .success(let details)):
                guard state.activeFetchGeneration == generation else { return .none }
                state.isLoading = false
                state.activeFetchGeneration = nil
                state.details = details
                state.errorRecovery = nil
                return .none

            case .deviceInfoLoaded(let generation, .failure(let error)):
                guard state.activeFetchGeneration == generation else { return .none }
                state.isLoading = false
                state.activeFetchGeneration = nil
                state.errorMessage = error.localizedDescription
                state.errorRecovery = .fetch
                return .none

            case .reboot(let mode, let confirmation):
                guard let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: "reboot:\(mode)") else {
                    state.errorMessage = String(localized: "The target device changed. Confirm Reboot again on the connected device.")
                    return .none
                }
                guard !state.isRebooting else { return .none }
                state.isRebooting = true
                state.errorMessage = nil
                state.errorRecovery = nil
                state.rebootStatusMessage = nil
                state.activeRebootMode = mode
                return .run { send in
                    try await adbClient.reboot(mode)
                    await send(.rebootResult(.success(())))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.rebootResult(.failure(error)))
                }
                .cancellable(id: CancelID.reboot, cancelInFlight: true)

            case .rebootResult(.success):
                state.isRebooting = false
                state.activeRebootMode = nil
                state.rebootStatusMessage = String(localized: "Reboot command sent. Waiting for the device to come back online…")
                return .none

            case .rebootResult(.failure(let error)):
                state.isRebooting = false
                state.errorMessage = error.localizedDescription
                // Reboot is destructive to the current session. Never offer an
                // automatic retry: the user must confirm the current target.
                state.errorRecovery = nil
                state.activeRebootMode = nil
                return .none

            case .retryError:
                switch state.errorRecovery {
                case .fetch: return .send(.fetchDeviceInfo)
                case nil: return .none
                }

            case .dismissError:
                state.errorMessage = nil
                state.errorRecovery = nil
                return .none

            case .cancelAll:
                state.isLoading = false
                state.activeFetchGeneration = nil
                state.isRebooting = false
                state.activeRebootMode = nil
                return .merge(
                    .cancel(id: CancelID.fetchInfo),
                    .cancel(id: CancelID.reboot)
                )
            }
        }
    }

    static func sourceIPAddress(from routeOutput: String) -> String? {
        guard let sourceRange = routeOutput.range(
            of: "\\bsrc\\s+(?:\\d{1,3}\\.){3}\\d{1,3}\\b",
            options: .regularExpression
        ) else { return nil }

        let sourceField = routeOutput[sourceRange]
        return sourceField.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    static func storageValues(from output: String) -> (total: String, available: String)? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4,
                  let totalKB = Int64(fields[1]),
                  let availableKB = Int64(fields[3]) else { continue }
            return (
                formatStorage(bytes: totalKB * 1_024),
                formatStorage(bytes: availableKB * 1_024)
            )
        }
        return nil
    }

    private static func formatStorage(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
