import Foundation
import ComposableArchitecture
import os

#if DEBUG
struct DebugSettings: Equatable, Codable, Sendable {
    var useAndroidEmulator = false
    var emulatorHost = "127.0.0.1"
    var emulatorPortInput = "5555"

    static let defaultValue = Self()

    var emulatorPort: UInt16 {
        guard let port = LocalizedDecimalInput.positiveUInt16(emulatorPortInput) else {
            return Self.defaultValue.emulatorPort
        }
        return port
    }

    var emulatorDevice: DiscoveredDevice {
        let settings = sanitized()
        return DiscoveredDevice(
            id: "debug-android-emulator",
            name: "Android Emulator",
            host: settings.emulatorHost,
            port: settings.emulatorPort,
            isPaired: true
        )
    }

    static func resolved(
        stored: Self,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        var settings = stored
        if arguments.contains("--iadb-debug-android-emulator") {
            settings.useAndroidEmulator = true
        }
        if let host = environment["IADB_DEBUG_ANDROID_HOST"] {
            settings.emulatorHost = host
        }
        if let port = environment["IADB_DEBUG_ANDROID_PORT"] {
            settings.emulatorPortInput = port
        }
        return settings.sanitized()
    }

    func sanitized() -> Self {
        var copy = self
        let host = emulatorHost.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.emulatorHost = host.isEmpty ? Self.defaultValue.emulatorHost : host
        copy.emulatorPortInput = String(emulatorPort)
        return copy
    }
}

struct DebugSettingsClient: Sendable {
    var load: @Sendable () -> DebugSettings
    var save: @Sendable (DebugSettings) -> Void
}

extension DebugSettingsClient: DependencyKey {
    private static let key = "debugSettings"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let settings = try? JSONDecoder().decode(DebugSettings.self, from: data) else {
                    return DebugSettings.resolved(stored: .defaultValue)
                }
                return DebugSettings.resolved(stored: settings)
            },
            save: { settings in
                guard let data = try? JSONEncoder().encode(settings.sanitized()) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        )
    }

    static var testValue: Self {
        Self(
            load: { .defaultValue },
            save: { _ in }
        )
    }
}

struct DebugEmulatorClient: Sendable {
    var isAvailable: @Sendable (_ host: String, _ port: UInt16) async -> Bool
}

extension DebugEmulatorClient: DependencyKey {
    static var liveValue: Self {
        Self(
            isAvailable: { host, port in
                let transport = ADBTransport()
                defer { transport.disconnect() }

                do {
                    try await transport.connect(host: host, port: port, timeout: 2)
                    try await transport.sendMessage(ADBMessage.connectMessage())
                    let response = try await transport.receiveMessage(timeout: 2)
                    return response.commandType == .connect
                        || response.commandType == .auth
                        || response.commandType == .stls
                } catch {
                    return false
                }
            }
        )
    }

    static var testValue: Self {
        Self(isAvailable: { _, _ in false })
    }
}

extension DependencyValues {
    var debugSettingsClient: DebugSettingsClient {
        get { self[DebugSettingsClient.self] }
        set { self[DebugSettingsClient.self] = newValue }
    }

    var debugEmulatorClient: DebugEmulatorClient {
        get { self[DebugEmulatorClient.self] }
        set { self[DebugEmulatorClient.self] = newValue }
    }
}
#endif

@Reducer
struct ConnectionFeature {
    struct ManualConnection: Equatable {
        let pairedDeviceID: UUID
        var deviceName: String
        var hostInput: String
        var portInput = ""
        var validationError: String?
    }

    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var discoveryError: String?
        var connectionState: ConnectionState = .disconnected
        var lastConnectionDevice: DiscoveredDevice?
        var lastConnectionError: String?
        var connectionGeneration = 0
        var activeConnectionGeneration: Int?
        var manualConnection: ManualConnection?
        var pendingForgetDeviceID: UUID?
        var isResetIdentityConfirmationPresented = false
        @Presents var pairing: PairingFeature.State?
        #if DEBUG
        var debugSettings: DebugSettings = .defaultValue
        var debugSettingsPresented = false
        #endif

        var offlinePairedDevices: [PairedDevice] {
            let matchedIDs = Set(discoveredDevices.compactMap {
                Self.pairedDevice(matching: $0, in: pairedDevices)?.id
            })
            return pairedDevices.filter { !matchedIDs.contains($0.id) }
        }

        var pendingForgetDevice: PairedDevice? {
            guard let pendingForgetDeviceID else { return nil }
            return pairedDevices.first { $0.id == pendingForgetDeviceID }
        }

        static func pairedDevice(
            matching discovered: DiscoveredDevice,
            in pairedDevices: [PairedDevice]
        ) -> PairedDevice? {
            if let guidMatch = pairedDevices.first(where: { $0.guid == discovered.id }) {
                return guidMatch
            }
            if let serviceMatch = pairedDevices.first(where: { $0.serviceName == discovered.id }) {
                return serviceMatch
            }
            return nil
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case startDiscovery
        case rescan
        case discoveryEvent(DeviceDiscoveryEvent)
        case discoveryStopped
        case devicesUpdated([DiscoveredDevice])
        case connectToDevice(DiscoveredDevice)
        case reconnectLastDevice
        case cancelConnection
        case disconnect
        case clearConnectionError
        case connectionResult(generation: Int, Result<String, Error>)
        case connectionLost(generation: Int, String)
        case showManualPairing
        case showPairingForDevice(DiscoveredDevice)
        case showManualConnection(PairedDevice)
        case manualConnectionHostChanged(String)
        case manualConnectionPortChanged(String)
        case dismissManualConnection
        case connectManualEndpoint
        case requestForgetPairedDevice(id: UUID)
        case cancelForgetPairedDevice
        case confirmForgetPairedDevice
        case requestResetADBIdentity
        case cancelResetADBIdentity
        case confirmResetADBIdentity
        case resetADBIdentitySucceeded
        case resetADBIdentityFailed(String)
        case pairing(PresentationAction<PairingFeature.Action>)
        #if DEBUG
        case showDebugSettings
        case hideDebugSettings
        case debugSettingsChanged
        #endif
    }

    private enum CancelID { case connection, connectionMonitor, discovery, pairingAutoConnect }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.pairedDevicesClient) var pairedDevicesClient
    @Dependency(\.deviceDiscoveryClient) var deviceDiscoveryClient
    #if DEBUG
    @Dependency(\.debugSettingsClient) var debugSettingsClient
    @Dependency(\.debugEmulatorClient) var debugEmulatorClient
    #endif

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                #if DEBUG
                return .send(.debugSettingsChanged)
                #else
                return .none
                #endif

            case .onAppear:
                state.pairedDevices = pairedDevicesClient.load()
                #if DEBUG
                state.debugSettings = debugSettingsClient.load()
                #endif
                return .send(.startDiscovery)

            case .startDiscovery:
                state.isScanning = true
                state.discoveryError = nil
                #if DEBUG
                if state.debugSettings.useAndroidEmulator {
                    let settings = state.debugSettings.sanitized()
                    return .run { send in
                        let isAvailable = await debugEmulatorClient.isAvailable(
                            settings.emulatorHost,
                            settings.emulatorPort
                        )
                        await send(.devicesUpdated(isAvailable ? [settings.emulatorDevice] : []))
                    }
                    .cancellable(id: CancelID.discovery, cancelInFlight: true)
                }
                #endif
                let pairedKeys = state.pairedDevices.map { Data($0.guid.utf8) }
                return .run { send in
                    let stream = deviceDiscoveryClient.start(pairedKeys)
                    var receivedEvent = false
                    for await event in stream {
                        receivedEvent = true
                        if case .devices(let devices) = event {
                            await send(.devicesUpdated(devices))
                        } else {
                            await send(.discoveryEvent(event))
                        }
                    }
                    if !receivedEvent {
                        await send(.discoveryStopped)
                    }
                }
                .cancellable(id: CancelID.discovery, cancelInFlight: true)

            case .rescan:
                state.discoveredDevices = []
                state.discoveryError = nil
                state.lastConnectionError = nil
                return .send(.startDiscovery)

            case .discoveryEvent(.ready):
                state.isScanning = false
                state.discoveryError = nil
                return .none

            case .discoveryEvent(.devices(let devices)):
                return .send(.devicesUpdated(devices))

            case .discoveryEvent(.failure(let message)):
                state.isScanning = false
                state.discoveryError = message
                return .none

            case .discoveryStopped:
                state.isScanning = false
                return .none

            case .devicesUpdated(var devices):
                let paired = state.pairedDevices
                for deviceIndex in devices.indices {
                    // Android returns ADB_DEVICE_GUID as the stable connect
                    // identity. Bonjour serviceName remains a migration
                    // fallback. An IP address is never an identity because
                    // DHCP can assign it to a different device.
                    let pairedDevice = State.pairedDevice(
                        matching: devices[deviceIndex],
                        in: paired
                    )
                    if let pairedDevice {
                        devices[deviceIndex].isPaired = true
                        devices[deviceIndex].name = pairedDevice.name
                    }
                }
                state.discoveredDevices = devices
                state.isScanning = false
                return .none

            case .connectToDevice(let device):
                guard state.connectionState != .connecting else { return .none }
                if state.connectionState.isConnected,
                   state.lastConnectionDevice?.id == device.id,
                   state.lastConnectionDevice?.host == device.host,
                   state.lastConnectionDevice?.port == device.port {
                    return .none
                }
                guard !state.connectionState.isConnected else {
                    state.lastConnectionError =
                        "Disconnect the current device before connecting to another one."
                    return .none
                }
                state.connectionState = .connecting
                state.lastConnectionDevice = device
                state.lastConnectionError = nil
                state.connectionGeneration += 1
                let generation = state.connectionGeneration
                state.activeConnectionGeneration = generation

                return .merge(
                    .cancel(id: CancelID.connectionMonitor),
                    .run { [host = device.host, port = device.port] send in
                        let banner = try await adbClient.connect(host, port)
                        await send(.connectionResult(generation: generation, .success(banner)))
                    } catch: { error, send in
                        guard !(error is CancellationError) else { return }
                        await send(.connectionResult(generation: generation, .failure(error)))
                    }
                    .cancellable(id: CancelID.connection, cancelInFlight: true)
                )

            case .reconnectLastDevice:
                guard let device = state.lastConnectionDevice else { return .none }
                return .send(.connectToDevice(device))

            case .cancelConnection:
                guard state.connectionState == .connecting else { return .none }
                state.connectionState = .disconnected
                state.lastConnectionError = nil
                state.activeConnectionGeneration = nil
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in adbClient.disconnect() }
                )

            case .disconnect:
                state.connectionState = .disconnected
                state.lastConnectionError = nil
                state.activeConnectionGeneration = nil
                return .merge(
                    .cancel(id: CancelID.connection),
                    .cancel(id: CancelID.pairingAutoConnect),
                    .cancel(id: CancelID.connectionMonitor),
                    .run { _ in adbClient.disconnect() }
                )

            case .clearConnectionError:
                state.lastConnectionError = nil
                if case .error = state.connectionState {
                    state.connectionState = .disconnected
                }
                return .none

            case .connectionResult(let generation, .success):
                guard state.connectionState == .connecting,
                      state.activeConnectionGeneration == generation else { return .none }
                state.connectionState = .connected
                state.lastConnectionError = nil
                return .run { send in
                    for await event in adbClient.connectionEvents() {
                        switch event {
                        case .disconnected(let reason):
                            await send(.connectionLost(generation: generation, reason))
                        }
                    }
                }
                .cancellable(id: CancelID.connectionMonitor, cancelInFlight: true)

            case .connectionResult(let generation, .failure(let error)):
                guard state.connectionState == .connecting,
                      state.activeConnectionGeneration == generation else { return .none }
                let message = error.localizedDescription
                state.connectionState = .error(message)
                state.lastConnectionError = message
                state.activeConnectionGeneration = nil
                return .none

            case .connectionLost(let generation, let reason):
                guard state.activeConnectionGeneration == generation,
                      state.connectionState.isConnected || state.connectionState == .connecting else {
                    return .none
                }
                state.connectionState = .error(reason)
                state.lastConnectionError = reason
                state.activeConnectionGeneration = nil
                return .merge(
                    .cancel(id: CancelID.connection),
                    .cancel(id: CancelID.connectionMonitor),
                    .run { _ in adbClient.disconnect() }
                )

            case .showManualPairing:
                state.pairing = PairingFeature.State()
                return .none

            case .showPairingForDevice(let device):
                state.pairing = PairingFeature.State(
                    hostInput: device.host,
                    portInput: device.pairingPort.map(String.init) ?? "",
                    isPrefilled: device.pairingPort != nil,
                    serviceName: device.id
                )
                return .none

            case .showManualConnection(let pairedDevice):
                state.manualConnection = ManualConnection(
                    pairedDeviceID: pairedDevice.id,
                    deviceName: pairedDevice.displayName,
                    hostInput: pairedDevice.lastHost
                )
                return .none

            case .manualConnectionHostChanged(let host):
                state.manualConnection?.hostInput = host
                state.manualConnection?.validationError = nil
                return .none

            case .manualConnectionPortChanged(let port):
                state.manualConnection?.portInput = port
                state.manualConnection?.validationError = nil
                return .none

            case .dismissManualConnection:
                state.manualConnection = nil
                return .none

            case .connectManualEndpoint:
                guard var manualConnection = state.manualConnection,
                      let pairedIndex = state.pairedDevices.firstIndex(where: {
                          $0.id == manualConnection.pairedDeviceID
                      })
                else { return .none }

                guard !state.connectionState.isConnected else {
                    manualConnection.validationError =
                        "Disconnect the current device before connecting to another one."
                    state.manualConnection = manualConnection
                    return .none
                }

                let host = manualConnection.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else {
                    manualConnection.validationError =
                        "Enter the IP address shown on Android's Wireless debugging screen."
                    state.manualConnection = manualConnection
                    return .none
                }
                guard let port = LocalizedDecimalInput.positiveUInt16(
                    manualConnection.portInput
                ) else {
                    manualConnection.validationError =
                        "Enter a valid Wireless debugging port (1–65535), not the pairing port."
                    state.manualConnection = manualConnection
                    return .none
                }

                state.pairedDevices[pairedIndex].lastHost = host
                let pairedDevice = state.pairedDevices[pairedIndex]
                let stableID = pairedDevice.serviceName
                    ?? (pairedDevice.guid.isEmpty
                        ? "saved-\(pairedDevice.id.uuidString)"
                        : pairedDevice.guid)
                let device = DiscoveredDevice(
                    id: stableID,
                    name: pairedDevice.displayName,
                    host: host,
                    port: port,
                    isPaired: true
                )
                state.manualConnection = nil
                return .merge(
                    .run { [devices = state.pairedDevices] _ in
                        pairedDevicesClient.save(devices)
                    },
                    .send(.connectToDevice(device))
                )

            case .requestForgetPairedDevice(let id):
                guard state.pairedDevices.contains(where: { $0.id == id }) else { return .none }
                state.pendingForgetDeviceID = id
                return .none

            case .cancelForgetPairedDevice:
                state.pendingForgetDeviceID = nil
                return .none

            case .confirmForgetPairedDevice:
                guard let id = state.pendingForgetDeviceID,
                      let removedDevice = state.pairedDevices.first(where: { $0.id == id })
                else { return .none }

                let pairedDevicesBeforeRemoval = state.pairedDevices
                let wasCurrentDevice = state.lastConnectionDevice.flatMap {
                    State.pairedDevice(matching: $0, in: pairedDevicesBeforeRemoval)
                }?.id == removedDevice.id
                let discoveredIndices = state.discoveredDevices.indices.filter { index in
                    State.pairedDevice(
                        matching: state.discoveredDevices[index],
                        in: pairedDevicesBeforeRemoval
                    )?.id == removedDevice.id
                }
                state.pendingForgetDeviceID = nil
                state.pairedDevices.removeAll { $0.id == id }
                if state.manualConnection?.pairedDeviceID == id {
                    state.manualConnection = nil
                }
                for index in discoveredIndices {
                    state.discoveredDevices[index].isPaired = false
                }
                if wasCurrentDevice {
                    state.lastConnectionDevice = nil
                    state.lastConnectionError = nil
                }

                let saveEffect: Effect<ConnectionFeature.Action> = .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }
                let cancelAutoConnect: Effect<ConnectionFeature.Action> = .cancel(
                    id: CancelID.pairingAutoConnect
                )
                if wasCurrentDevice && (state.connectionState.isConnected || state.connectionState == .connecting) {
                    return .merge(saveEffect, cancelAutoConnect, .send(.disconnect))
                }
                return .merge(saveEffect, cancelAutoConnect)

            case .requestResetADBIdentity:
                state.isResetIdentityConfirmationPresented = true
                return .none

            case .cancelResetADBIdentity:
                state.isResetIdentityConfirmationPresented = false
                return .none

            case .confirmResetADBIdentity:
                guard state.isResetIdentityConfirmationPresented else { return .none }
                state.isResetIdentityConfirmationPresented = false
                return .concatenate(
                    .send(.disconnect),
                    .run { send in
                        do {
                            try adbClient.resetIdentity()
                            pairedDevicesClient.save([])
                            await send(.resetADBIdentitySucceeded)
                        } catch {
                            await send(.resetADBIdentityFailed(error.localizedDescription))
                        }
                    }
                )

            case .resetADBIdentitySucceeded:
                state.pairedDevices = []
                state.manualConnection = nil
                state.pendingForgetDeviceID = nil
                state.pairing = nil
                state.lastConnectionDevice = nil
                state.lastConnectionError = nil
                state.discoveryError = nil
                for index in state.discoveredDevices.indices {
                    state.discoveredDevices[index].isPaired = false
                }
                return .send(.startDiscovery)

            case .resetADBIdentityFailed(let errorMessage):
                state.lastConnectionError =
                    "The ADB identity could not be removed. Unlock this iPhone or iPad and try again. "
                    + errorMessage
                return .none

            #if DEBUG
            case .showDebugSettings:
                state.debugSettingsPresented = true
                return .none

            case .hideDebugSettings:
                guard state.debugSettingsPresented else { return .none }
                state.debugSettingsPresented = false
                return .none

            case .debugSettingsChanged:
                state.discoveredDevices = []
                state.discoveryError = nil
                state.lastConnectionError = nil
                let settings = state.debugSettings.sanitized()
                return .merge(
                    .run { _ in debugSettingsClient.save(settings) },
                    .send(.startDiscovery)
                )
            #endif

            case .pairing(.presented(.pairingCompleted(let name, let guid))):
                guard let pairingState = state.pairing else { return .none }
                let host = pairingState.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }

                let serviceName = pairingState.serviceName
                if let svc = serviceName {
                    state.pairedDevices.removeAll { $0.serviceName == svc }
                } else {
                    state.pairedDevices.removeAll { $0.guid == guid }
                }
                let discoveredName = serviceName.flatMap { service in
                    state.discoveredDevices.first { $0.id == service }?.name
                }
                let displayName = discoveredName.flatMap { $0.isEmpty ? nil : $0 } ?? name
                let paired = PairedDevice(name: displayName, guid: guid, lastHost: host, serviceName: serviceName)
                state.pairedDevices.append(paired)

                if let svc = serviceName,
                   let idx = state.discoveredDevices.firstIndex(where: { $0.id == svc }) {
                    state.discoveredDevices[idx].isPaired = true
                    state.discoveredDevices[idx].name = name
                }

                // Only a stable Bonjour service identity may select a device.
                // An IP address can be reassigned by DHCP and is never identity.
                let connectDevice = serviceName.flatMap { svc in
                    state.discoveredDevices.first(where: { $0.id == svc })
                }

                let log = Logger(subsystem: "com.iadb.app", category: "adb")
                if let device = connectDevice {
                    let endpoint = "\(device.host):\(device.port)"
                    log.info(
                        "AUTO-CONNECT pairedHost=\(host, privacy: .private(mask: .hash)) → discovered=\(endpoint, privacy: .private(mask: .hash))"
                    )
                } else {
                    let allHosts = state.discoveredDevices.map { "\($0.host):\($0.port)" }.joined(separator: ",")
                    let message = "AUTO-CONNECT no discovered device for pairedHost=\(host). Discovered: \(allHosts)"
                    log.error("\(message, privacy: .private(mask: .hash))")
                }
                let saveEffect: Effect<ConnectionFeature.Action> = .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }
                let dismissEffect: Effect<ConnectionFeature.Action> = .send(.pairing(.dismiss))
                if let device = connectDevice {
                    // Задержка нужна, чтобы adbd успел зарегистрировать новый ключ
                    // в trusted-list перед нашим TLS-подключением (race на commit).
                    let delayedConnect: Effect<ConnectionFeature.Action> = .run { send in
                        do {
                            try await Task.sleep(nanoseconds: 1_500_000_000)
                        } catch {
                            return
                        }
                        await send(.connectToDevice(device))
                    }
                    .cancellable(id: CancelID.pairingAutoConnect, cancelInFlight: true)
                    return .merge(saveEffect, dismissEffect, delayedConnect)
                }
                // The pairing endpoint is different from the normal Wireless
                // debugging endpoint. Keep a visible next step instead of
                // dismissing into an offline device that cannot be opened.
                state.manualConnection = ManualConnection(
                    pairedDeviceID: paired.id,
                    deviceName: paired.displayName,
                    hostInput: host
                )
                return .merge(saveEffect, dismissEffect)

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
