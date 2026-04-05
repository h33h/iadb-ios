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

            case .connection(.connectionResult(.success)):
                // On successful connection, fetch initial data
                return .merge(
                    .send(.device(.fetchDeviceInfo)),
                    .send(.fileManager(.loadDirectory(path: nil))),
                    .send(.apps(.loadApps))
                )

            case .connection(.disconnect):
                // Reset child states on disconnect
                state.device = DeviceInfoFeature.State()
                state.apps = AppsFeature.State()
                state.fileManager = FileManagerFeature.State()
                state.shell = ShellFeature.State()
                state.logcat = LogcatFeature.State()
                state.screenshot = ScreenshotFeature.State()
                return .none

            default:
                return .none
            }
        }
    }
}
