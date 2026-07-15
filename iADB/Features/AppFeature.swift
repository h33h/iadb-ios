import Foundation
import ComposableArchitecture

@Reducer
struct AppFeature {
    enum Tab: Int, Equatable {
        // Legacy values remain valid for state restoration and reducer tests.
        // `visibleRoot` folds them into the five task-oriented tabs.
        case connection = 0
        case device = 1
        case files = 2
        case apps = 3
        case shell = 4
        case logcat = 5
        case screenshot = 6
        case console = 7
        case screens = 8

        var visibleRoot: Self {
            switch self {
            case .connection, .device: .device
            case .files: .files
            case .apps: .apps
            case .shell, .logcat, .console: .console
            case .screenshot, .screens: .screens
            }
        }
    }

    @ObservableState
    struct State: Equatable {
        /// The workspace becomes available after the first successful connection in this app session.
        /// A later disconnect intentionally keeps this true so remote context remains available offline.
        var hasEnteredWorkspace = false
        var isConnectionSetupPresented = false
        var appShell = AppShellFeature.State()
        var selectedTab: Tab {
            get { appShell.selectedRoot.legacyTab }
            set { appShell.selectedRoot = newValue.shellRoot }
        }
        var session = DeviceSessionFeature.State()
        var operations = OperationCenterFeature.State()
        var feedback = FeedbackFeature.State()
        var connection = ConnectionFeature.State()
        var device = DeviceInfoFeature.State()
        var apps = AppsFeature.State()
        var fileManager = FileManagerFeature.State()
        var shell = ShellFeature.State()
        var logcat = LogcatFeature.State()
        var screenshot = ScreenshotFeature.State()
    }

    enum Action {
        case showConnectionSetup
        case selectTab(Tab)
        case refreshSelectedRoot
        case appShell(AppShellFeature.Action)
        case session(DeviceSessionFeature.Action)
        case operations(OperationCenterFeature.Action)
        case feedback(FeedbackFeature.Action)
        case connection(ConnectionFeature.Action)
        case device(DeviceInfoFeature.Action)
        case apps(AppsFeature.Action)
        case fileManager(FileManagerFeature.Action)
        case shell(ShellFeature.Action)
        case logcat(LogcatFeature.Action)
        case screenshot(ScreenshotFeature.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.appShell, action: \.appShell) {
            AppShellFeature()
        }
        Scope(state: \.session, action: \.session) {
            DeviceSessionFeature()
        }
        Scope(state: \.operations, action: \.operations) {
            OperationCenterFeature()
        }
        Scope(state: \.feedback, action: \.feedback) {
            FeedbackFeature()
        }
        Scope(state: \.connection, action: \.connection) {
            ConnectionFeature()
        }
        Scope(state: \.device, action: \.device) {
            DeviceInfoFeature()
        }
        Scope(state: \.apps, action: \.apps) {
            AppsFeature()
        }
        Scope(state: \.fileManager, action: \.fileManager) {
            FileManagerFeature()
        }
        Scope(state: \.shell, action: \.shell) {
            ShellFeature()
        }
        Scope(state: \.logcat, action: \.logcat) {
            LogcatFeature()
        }
        Scope(state: \.screenshot, action: \.screenshot) {
            ScreenshotFeature()
        }
        Reduce { state, action in
            switch action {
            case .showConnectionSetup:
                state.isConnectionSetupPresented = true
                return .none

            case .selectTab(let tab):
                state.selectedTab = tab
                return .none

            case .refreshSelectedRoot:
                switch state.appShell.selectedRoot {
                case .device:
                    return .send(.device(.fetchDeviceInfo))
                case .files:
                    return .send(.fileManager(.loadDirectory(path: nil)))
                case .apps:
                    return .send(.apps(.loadApps))
                case .console:
                    switch state.appShell.consoleSection {
                    case .commandRunner: return .none
                    case .logcat: return .send(.logcat(.startLogcat))
                    }
                case .screens:
                    return .send(.screenshot(.loadPersistence))
                }

            case .connection(.connectToDevice(let device)):
                guard state.connection.connectionState == .connecting,
                      state.connection.lastConnectionDevice == device,
                      let generation = state.connection.activeConnectionGeneration else { return .none }
                let identity = deviceIdentity(for: device, connection: state.connection)
                let switchedAt = state.apps.remoteTarget.deviceID == identity.stableID
                    ? state.apps.remoteTarget.switchedAt
                    : date.now
                state.apps.remoteTarget = RemoteDeviceTarget(
                    deviceID: identity.stableID,
                    deviceName: identity.displayName,
                    transportGeneration: generation,
                    switchedAt: switchedAt,
                    isConnected: false
                )
                state.fileManager.remoteTarget = state.apps.remoteTarget
                state.device.remoteTarget = state.apps.remoteTarget
                return .merge(
                    .send(.session(.connectionStarted(
                        identity: identity,
                        endpoint: Endpoint(host: device.host, port: device.port),
                        date: date.now
                    ))),
                    .send(.shell(.setActiveDevice(identity.stableID))),
                    .send(.logcat(.setActiveDevice(identity.stableID))),
                    .send(.screenshot(.setActiveDevice(identity)))
                )

            case .connection(.connectionResult(let generation, .success)):
                // On successful connection, fetch initial data
                guard state.connection.connectionState.isConnected,
                      state.connection.activeConnectionGeneration == generation else { return .none }
                guard let device = state.connection.lastConnectionDevice else { return .none }
                state.hasEnteredWorkspace = true
                state.isConnectionSetupPresented = false
                if state.apps.remoteTarget.transportGeneration == generation {
                    state.apps.remoteTarget.isConnected = true
                    state.fileManager.remoteTarget.isConnected = true
                    state.device.remoteTarget.isConnected = true
                }
                return .merge(
                    .send(.session(.connectionSucceeded(
                        identity: deviceIdentity(for: device, connection: state.connection),
                        endpoint: Endpoint(host: device.host, port: device.port),
                        date: date.now
                    ))),
                    .send(.device(.fetchDeviceInfo)),
                    .send(.fileManager(.loadDirectory(path: nil))),
                    .send(.apps(.loadApps))
                )

            case .connection(.connectionResult(_, .failure(let error))):
                state.apps.remoteTarget.isConnected = false
                state.fileManager.remoteTarget.isConnected = false
                state.device.remoteTarget.isConnected = false
                let deviceID = state.session.selectedDeviceID
                return .merge(
                    .send(.session(.disconnected(
                        reason: .connectionFailed(error.localizedDescription),
                        date: date.now
                    ))),
                    deviceID.map {
                        .send(.operations(.transportDisconnected(
                            deviceID: $0,
                            message: String(localized: "Connection failed: \(error.localizedDescription)"),
                            date: date.now
                        )))
                    } ?? .none
                )

            case .connection(.disconnect):
                state.apps.remoteTarget.isConnected = false
                state.fileManager.remoteTarget.isConnected = false
                state.device.remoteTarget.isConnected = false
                let deviceID = state.session.selectedDeviceID
                return .concatenate(
                    .send(.session(.disconnected(reason: .userInitiated, date: date.now))),
                    deviceID.map {
                        .send(.operations(.transportDisconnected(
                            deviceID: $0,
                            message: String(localized: "Disconnected from the target device."),
                            date: date.now
                        )))
                    } ?? .none,
                    transportCancellationEffect()
                )

            case .connection(.connectionLost(_, let reason)):
                state.apps.remoteTarget.isConnected = false
                state.fileManager.remoteTarget.isConnected = false
                state.device.remoteTarget.isConnected = false
                let deviceID = state.session.selectedDeviceID
                return .concatenate(
                    .send(.session(.disconnected(reason: .transport(reason), date: date.now))),
                    deviceID.map {
                        .send(.operations(.transportDisconnected(
                            deviceID: $0,
                            message: reason,
                            date: date.now
                        )))
                    } ?? .none,
                    transportCancellationEffect()
                )

            case .operations(.delegate(.cancel(let id, let kind))):
                switch kind {
                case .capture:
                    guard state.screenshot.activeCaptureOperationID == id else { return .none }
                    return .send(.screenshot(.cancelCapture))
                case .installAPK:
                    guard state.apps.activeInstallID == id else { return .none }
                    return .send(.apps(.cancelInstall))
                case .appMutation:
                    guard state.apps.bulkUninstall?.id == id else { return .none }
                    return .send(.apps(.cancelBulkUninstall))
                case .upload, .download:
                    guard state.fileManager.activeBackgroundOperationID == id else { return .none }
                    return .send(.fileManager(.cancelTransfer(id: id)))
                default:
                    return .none
                }

            case .operations(.delegate(.retry(_, .captureScreenshot))):
                guard state.session.capabilities.canCaptureScreen else {
                    return .send(.feedback(.showToast(
                        id: uuid(),
                        message: DeviceCapabilities.disconnectedReason.message,
                        symbol: "wifi.slash"
                    )))
                }
                return .send(.screenshot(.takeScreenshot))

            case .operations(.delegate(.retry(_, .download(let remotePath)))):
                guard state.session.capabilities.canReadRemoteFiles else {
                    return .send(.feedback(.showToast(
                        id: uuid(),
                        message: String(localized: "Reconnect to the target device before retrying the download."),
                        symbol: "wifi.slash"
                    )))
                }
                return .send(.fileManager(.retryDownload(remotePath: remotePath)))

            case .screenshot(.delegate(.operationStarted(let operation))):
                return .send(.operations(.operationStarted(operation)))

            case .screenshot(.delegate(.operationPhase(let id, let phase, let detail))):
                return .send(.operations(.operationPhase(id: id, phase: phase, detail: detail)))

            case .screenshot(.delegate(.operationFinished(let id, let outcome, let finishedAt))):
                return .send(.operations(.operationFinished(
                    id: id,
                    outcome: outcome,
                    date: finishedAt
                )))

            case .screenshot(.delegate(.cleanupCompleted(let id, let didCleanUp))):
                return .send(.operations(.cleanupCompleted(id: id, .success(didCleanUp))))

            case .screenshot(.delegate(.showToast(let message, let symbol))):
                return .send(.feedback(.showToast(
                    id: uuid(),
                    message: message,
                    symbol: symbol
                )))

            case .apps(.delegate(.operationStarted(let operation))):
                return .send(.operations(.operationStarted(operation)))

            case .apps(.delegate(.operationPhase(let id, let phase, let detail))):
                return .send(.operations(.operationPhase(id: id, phase: phase, detail: detail)))

            case .apps(.delegate(.operationFinished(let id, let outcome, let finishedAt))):
                return .send(.operations(.operationFinished(
                    id: id,
                    outcome: outcome,
                    date: finishedAt
                )))

            case .apps(.delegate(.cleanupCompleted(let id, let result))):
                return .send(.operations(.cleanupCompleted(id: id, result)))

            case .apps(.getAppDetail(let app)):
                state.appShell.detailSelections[.apps] = .app(packageName: app.packageName)
                return .none

            case .apps(.selectInspector(let app)):
                state.appShell.detailSelections[.apps] = app.map {
                    .app(packageName: $0.packageName)
                }
                return .none

            case .shell(.selectHistory(let id)):
                state.appShell.detailSelections[.console] = id.map {
                    .shellCommand($0)
                }
                return .none

            case .logcat(.selectEntry(let id)):
                state.appShell.detailSelections[.console] = id.map {
                    .logEntry($0)
                }
                return .none

            case .fileManager(.selectFile(let entry)):
                state.appShell.detailSelections[.files] = entry.map {
                    .file(path: $0.fullPath)
                }
                return .none

            case .fileManager(.selectInspector(let entry)):
                state.appShell.detailSelections[.files] = entry.map {
                    .file(path: $0.fullPath)
                }
                return .none

            case .fileManager(.navigateTo(let entry)) where !entry.isNavigableDirectory:
                state.appShell.detailSelections[.files] = .file(path: entry.fullPath)
                return .none

            case .screenshot(.selectScreenshot(let screenshot)):
                state.appShell.detailSelections[.screens] = screenshot.map {
                    .screenshot($0.id)
                }
                return .none

            case .screenshot(.deleteScreenshot(let screenshot)):
                if state.appShell.detailSelections[.screens] == .screenshot(screenshot.id) {
                    state.appShell.detailSelections[.screens] = nil
                }
                return .none

            case .screenshot(.bulkDeleteSelected):
                if case .screenshot(let id) = state.appShell.detailSelections[.screens],
                   state.screenshot.selectedScreenshotIDs.contains(id) {
                    state.appShell.detailSelections[.screens] = nil
                }
                return .none

            case .screenshot(.clearAll):
                state.appShell.detailSelections[.screens] = nil
                return .none

            case .fileManager(.delegate(.operationStarted(let operation))):
                return .send(.operations(.operationStarted(operation)))

            case .fileManager(.delegate(.operationPhase(let id, let phase, let detail))):
                return .send(.operations(.operationPhase(id: id, phase: phase, detail: detail)))

            case .fileManager(.delegate(.operationProgress(let id, let completed, let total))):
                return .send(.operations(.progress(id: id, completed: completed, total: total)))

            case .fileManager(.delegate(.operationFinished(let id, let outcome, let finishedAt))):
                return .send(.operations(.operationFinished(
                    id: id,
                    outcome: outcome,
                    date: finishedAt
                )))

            case .fileManager(.delegate(.cleanupCompleted(let id, let result))):
                return .send(.operations(.cleanupCompleted(id: id, result)))

            case .device(.deviceInfoLoaded(_, .success)):
                return .send(.session(.markSnapshotCurrent(.device, date: date.now)))

            case .fileManager(.directoryLoaded(_, .success, _)):
                return .send(.session(.markSnapshotCurrent(.files, date: date.now)))

            case .apps(.appsLoaded(_, _, _, .success)):
                return .send(.session(.markSnapshotCurrent(.apps, date: date.now)))

            case .device(.rebootResult(.success)):
                guard let generation = state.connection.activeConnectionGeneration else { return .none }
                return .send(
                    .connection(
                        .connectionLost(
                            generation: generation,
                            String(localized: "The Android device is rebooting. Wait until Wireless debugging is available, then tap Reconnect or Rescan.")
                        )
                    )
                )

            default:
                return .none
            }
        }
    }

    @Dependency(\.date) private var date
    @Dependency(\.uuid) private var uuid

    private func transportCancellationEffect() -> Effect<Action> {
        .merge(
            .send(.device(.cancelAll)),
            .send(.apps(.cancelAll)),
            .send(.fileManager(.cancelCurrentOperation)),
            .send(.shell(.cancelAll)),
            .send(.logcat(.stopLogcat)),
            .send(.screenshot(.cancelCapture))
        )
    }

    private func deviceIdentity(
        for device: DiscoveredDevice,
        connection: ConnectionFeature.State
    ) -> DeviceIdentity {
        DeviceIdentity.resolved(from: device, pairedDevices: connection.pairedDevices)
    }
}

private extension AppFeature.Tab {
    var shellRoot: AppShellFeature.Root {
        switch visibleRoot {
        case .device, .connection: .device
        case .files: .files
        case .apps: .apps
        case .shell, .logcat, .console: .console
        case .screenshot, .screens: .screens
        }
    }
}

private extension AppShellFeature.Root {
    var legacyTab: AppFeature.Tab {
        switch self {
        case .device: .device
        case .files: .files
        case .apps: .apps
        case .console: .console
        case .screens: .screens
        }
    }
}
