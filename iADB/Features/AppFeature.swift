import Foundation
import ComposableArchitecture

@Reducer
struct AppFeature {
    enum Tab: Int, Equatable {
        case connection = 0
        case device = 1
        case files = 2
        case apps = 3
        case shell = 4
        case logcat = 5
        case screenshot = 6
    }

    @ObservableState
    struct State: Equatable {
        var selectedTab: Tab = .connection
        var connection = ConnectionFeature.State()
        var device = DeviceInfoFeature.State()
        var apps = AppsFeature.State()
        var fileManager = FileManagerFeature.State()
        var shell = ShellFeature.State()
        var logcat = LogcatFeature.State()
        var screenshot = ScreenshotFeature.State()
    }

    enum Action {
        case selectTab(Tab)
        case connection(ConnectionFeature.Action)
        case device(DeviceInfoFeature.Action)
        case apps(AppsFeature.Action)
        case fileManager(FileManagerFeature.Action)
        case shell(ShellFeature.Action)
        case logcat(LogcatFeature.Action)
        case screenshot(ScreenshotFeature.Action)
        case resetDisconnectedChildren(returnToConnection: Bool)
    }

    var body: some ReducerOf<Self> {
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
            case .selectTab(let tab):
                state.selectedTab = tab
                return .none

            case .connection(.connectionResult(let generation, .success)):
                // On successful connection, fetch initial data
                guard state.connection.connectionState.isConnected,
                      state.connection.activeConnectionGeneration == generation else { return .none }
                return .merge(
                    .send(.device(.fetchDeviceInfo)),
                    .send(.fileManager(.loadDirectory(path: nil))),
                    .send(.apps(.loadApps))
                )

            case .connection(.disconnect):
                return lifecycleResetEffect(returnToConnection: false)

            case .connection(.connectionLost):
                return lifecycleResetEffect(returnToConnection: true)

            case .resetDisconnectedChildren(let returnToConnection):
                if returnToConnection {
                    state.selectedTab = .connection
                }
                // The Shell reducer's persistence writer lives for the store's
                // lifetime. Keep its monotonically increasing generation when
                // clearing device-specific UI so later saves are not mistaken
                // for stale pre-disconnect snapshots.
                let shellPersistenceGeneration = state.shell.persistenceGeneration
                state.device = DeviceInfoFeature.State()
                state.apps = AppsFeature.State()
                state.fileManager = FileManagerFeature.State()
                state.shell = ShellFeature.State()
                state.shell.persistenceGeneration = shellPersistenceGeneration
                state.logcat = LogcatFeature.State()
                state.screenshot = ScreenshotFeature.State()
                return .none

            case .device(.rebootResult(.success)):
                guard let generation = state.connection.activeConnectionGeneration else { return .none }
                return .send(
                    .connection(
                        .connectionLost(
                            generation: generation,
                            "The Android device is rebooting. Wait until Wireless debugging is available, "
                                + "then tap Reconnect or Rescan."
                        )
                    )
                )

            default:
                return .none
            }
        }
    }

    private func lifecycleResetEffect(returnToConnection: Bool) -> Effect<Action> {
        .concatenate(
            .send(.device(.cancelAll)),
            .send(.apps(.cancelAll)),
            .send(.fileManager(.cancelCurrentOperation)),
            .send(.shell(.cancelAll)),
            .send(.logcat(.stopLogcat)),
            .send(.screenshot(.cancelAll)),
            .send(.resetDisconnectedChildren(returnToConnection: returnToConnection))
        )
    }
}
