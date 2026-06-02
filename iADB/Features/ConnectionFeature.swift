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
        let rawPort = emulatorPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(rawPort), port > 0 else {
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
    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var connectionState: ConnectionState = .disconnected
        var lastConnectionDevice: DiscoveredDevice?
        var lastConnectionError: String?
        @Presents var pairing: PairingFeature.State?
        #if DEBUG
        var debugSettings: DebugSettings = .defaultValue
        var debugSettingsPresented = false
        #endif
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case startDiscovery
        case rescan
        case devicesUpdated([DiscoveredDevice])
        case connectToDevice(DiscoveredDevice)
        case reconnectLastDevice
        case disconnect
        case clearConnectionError
        case connectionResult(Result<String, Error>)
        case showManualPairing
        case showPairingForDevice(DiscoveredDevice)
        case removePairedDevice(serviceName: String)
        case pairing(PresentationAction<PairingFeature.Action>)
        #if DEBUG
        case showDebugSettings
        case hideDebugSettings
        case debugSettingsChanged
        #endif
    }

    private enum CancelID { case connection, discovery }

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
                #if DEBUG
                if state.debugSettings.useAndroidEmulator {
                    let settings = state.debugSettings.sanitized()
                    return .run { send in
                        let isAvailable = await debugEmulatorClient.isAvailable(settings.emulatorHost, settings.emulatorPort)
                        await send(.devicesUpdated(isAvailable ? [settings.emulatorDevice] : []))
                    }
                    .cancellable(id: CancelID.discovery, cancelInFlight: true)
                }
                #endif
                let pairedKeys = state.pairedDevices.map(\.publicKey)
                return .run { send in
                    let stream = deviceDiscoveryClient.start(pairedKeys)
                    for await devices in stream {
                        await send(.devicesUpdated(devices))
                    }
                }
                .cancellable(id: CancelID.discovery, cancelInFlight: true)

            case .rescan:
                state.discoveredDevices = []
                state.lastConnectionError = nil
                return .send(.startDiscovery)

            case .devicesUpdated(var devices):
                let paired = state.pairedDevices
                for i in devices.indices {
                    // Матчим по serviceName (стабильный hash cert), а не по host.
                    // host меняется при toggle wireless debug, serviceName — нет.
                    if let match = paired.first(where: { $0.serviceName == devices[i].id })
                        ?? paired.first(where: { $0.lastHost == devices[i].host }) // fallback для старых записей без serviceName
                    {
                        devices[i].isPaired = true
                        devices[i].name = match.name
                    }
                }
                state.discoveredDevices = devices
                state.isScanning = false
                return .none

            case .connectToDevice(let device):
                guard state.connectionState != .connecting else { return .none }
                state.connectionState = .connecting
                state.lastConnectionDevice = device
                state.lastConnectionError = nil

                return .run { [host = device.host, port = device.port] send in
                    let banner = try await adbClient.connect(host, port)
                    await send(.connectionResult(.success(banner)))
                } catch: { error, send in
                    await send(.connectionResult(.failure(error)))
                }
                .cancellable(id: CancelID.connection)

            case .reconnectLastDevice:
                guard let device = state.lastConnectionDevice else { return .none }
                return .send(.connectToDevice(device))

            case .disconnect:
                state.connectionState = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in adbClient.disconnect() }
                )

            case .clearConnectionError:
                state.lastConnectionError = nil
                if case .error = state.connectionState {
                    state.connectionState = .disconnected
                }
                return .none

            case .connectionResult(.success):
                state.connectionState = .connected
                state.lastConnectionError = nil
                return .none

            case .connectionResult(.failure(let error)):
                let message = error.localizedDescription
                state.connectionState = .error(message)
                state.lastConnectionError = message
                return .none

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

            case .removePairedDevice(let serviceName):
                state.pairedDevices.removeAll { $0.serviceName == serviceName }
                for i in state.discoveredDevices.indices where state.discoveredDevices[i].id == serviceName {
                    state.discoveredDevices[i].isPaired = false
                }
                return .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }

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
                state.lastConnectionError = nil
                let settings = state.debugSettings.sanitized()
                return .merge(
                    .run { _ in debugSettingsClient.save(settings) },
                    .send(.startDiscovery)
                )
            #endif

            case .pairing(.presented(.pairingCompleted(let name, let publicKey))):
                guard let pairingState = state.pairing else { return .none }
                let host = pairingState.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }

                let serviceName = pairingState.serviceName
                if let svc = serviceName {
                    state.pairedDevices.removeAll { $0.serviceName == svc }
                } else {
                    state.pairedDevices.removeAll { $0.publicKey == publicKey }
                }
                let paired = PairedDevice(name: name, publicKey: publicKey, lastHost: host, serviceName: serviceName)
                state.pairedDevices.append(paired)

                if let svc = serviceName,
                   let idx = state.discoveredDevices.firstIndex(where: { $0.id == svc }) {
                    state.discoveredDevices[idx].isPaired = true
                    state.discoveredDevices[idx].name = name
                }

                // Auto-connect after pairing — ищем по serviceName, host мог уже измениться
                let connectDevice = serviceName.flatMap { svc in
                    state.discoveredDevices.first(where: { $0.id == svc })
                } ?? state.discoveredDevices.first(where: { $0.host == host })

                let log = Logger(subsystem: "com.iadb.app", category: "adb")
                if let d = connectDevice {
                    let endpoint = "\(d.host):\(d.port)"
                    log.info("AUTO-CONNECT pairedHost=\(host, privacy: .public) → discovered=\(endpoint, privacy: .public)")
                } else {
                    let allHosts = state.discoveredDevices.map { "\($0.host):\($0.port)" }.joined(separator: ",")
                    log.error("AUTO-CONNECT no discovered device for pairedHost=\(host, privacy: .public). Discovered: \(allHosts, privacy: .public)")
                }
                state.pairing = nil // dismiss pairing sheet

                let saveEffect: Effect<ConnectionFeature.Action> = .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }
                if let device = connectDevice {
                    // Задержка нужна, чтобы adbd успел зарегистрировать новый ключ
                    // в trusted-list перед нашим TLS-подключением (race на commit).
                    let delayedConnect: Effect<ConnectionFeature.Action> = .run { send in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await send(.connectToDevice(device))
                    }
                    return .merge(saveEffect, delayedConnect)
                }
                return saveEffect

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
