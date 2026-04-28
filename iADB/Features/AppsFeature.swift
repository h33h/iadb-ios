import Foundation
import ComposableArchitecture

@Reducer
struct AppsFeature {
    @ObservableState
    struct State: Equatable {
        var apps: [AppInfo] = []
        var isLoading = false
        var errorMessage: String?
        var statusMessage: String?
        var showSystemApps = false
        var searchText = ""
        var selectedApp: AppInfo?
        var showingAppDetail = false
        var appDetailText = ""
        var isInstalling = false
        var installProgress = ""

        var filteredApps: [AppInfo] {
            guard !searchText.isEmpty else { return apps }
            return apps.filter {
                $0.packageName.localizedCaseInsensitiveContains(searchText) ||
                ($0.appName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case loadApps
        case appsLoaded(Result<[AppInfo], Error>)
        case uninstall(AppInfo, keepData: Bool)
        case forceStop(AppInfo)
        case clearData(AppInfo)
        case getAppDetail(AppInfo)
        case installAPK(data: Data, fileName: String)
        case launchApp(AppInfo)
        case operationResult(Result<String, Error>)
        case appDetailLoaded(Result<String, Error>)
        case installResult(Result<String, Error>)
        case dismissStatus
        case toggleSystemApps
    }

    private enum CancelID { case loadApps, operation }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .loadApps:
                state.isLoading = true
                state.errorMessage = nil
                let includeSystem = state.showSystemApps

                return .run { send in
                    async let allPackages = adbClient.listPackages(true)
                    async let userPackages = adbClient.listPackages(false)
                    let all = try await allPackages
                    let user = Set(try await userPackages)
                    let apps = all.map { pkg in
                        AppInfo(packageName: pkg, isSystemApp: !user.contains(pkg))
                    }
                    let filtered = includeSystem ? apps : apps.filter { !$0.isSystemApp }
                    await send(.appsLoaded(.success(filtered)))
                } catch: { error, send in
                    await send(.appsLoaded(.failure(error)))
                }
                .cancellable(id: CancelID.loadApps, cancelInFlight: true)

            case .appsLoaded(.success(let apps)):
                state.isLoading = false
                state.apps = apps
                return .none

            case .appsLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .uninstall(let app, let keepData):
                state.statusMessage = nil
                return .run { send in
                    let result = try await adbClient.uninstallPackage(app.packageName, keepData)
                    await send(.operationResult(.success(result)))
                    await send(.loadApps)
                } catch: { error, send in
                    await send(.operationResult(.failure(error)))
                }

            case .forceStop(let app):
                return .run { send in
                    try await adbClient.forceStopApp(app.packageName)
                    await send(.operationResult(.success("Force stopped \(app.packageName)")))
                } catch: { error, send in
                    await send(.operationResult(.failure(error)))
                }

            case .clearData(let app):
                return .run { send in
                    let result = try await adbClient.clearAppData(app.packageName)
                    await send(.operationResult(.success(result)))
                } catch: { error, send in
                    await send(.operationResult(.failure(error)))
                }

            case .getAppDetail(let app):
                state.selectedApp = app
                return .run { send in
                    let detail = try await adbClient.getAppInfo(app.packageName)
                    await send(.appDetailLoaded(.success(detail)))
                } catch: { error, send in
                    await send(.appDetailLoaded(.failure(error)))
                }

            case .appDetailLoaded(.success(let detail)):
                state.appDetailText = detail
                state.showingAppDetail = true
                return .none

            case .appDetailLoaded(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .installAPK(let data, let fileName):
                state.isInstalling = true
                state.installProgress = "Pushing APK to device..."
                state.errorMessage = nil

                return .run { send in
                    let remotePath = "/data/local/tmp/\(fileName)"
                    try await adbClient.pushData(data, remotePath, 0o644)
                    let result = try await adbClient.shell("pm install -r \"\(remotePath)\"")
                    _ = try? await adbClient.shell("rm \"\(remotePath)\"")
                    await send(.installResult(.success(result)))
                    await send(.loadApps)
                } catch: { error, send in
                    await send(.installResult(.failure(error)))
                }

            case .installResult(.success(let result)):
                state.isInstalling = false
                state.installProgress = ""
                state.statusMessage = result
                return .none

            case .installResult(.failure(let error)):
                state.isInstalling = false
                state.installProgress = ""
                state.errorMessage = error.localizedDescription
                return .none

            case .launchApp(let app):
                return .run { send in
                    _ = try await adbClient.shell("monkey -p \(app.packageName) -c android.intent.category.LAUNCHER 1")
                    await send(.operationResult(.success("Launched \(app.packageName)")))
                } catch: { error, send in
                    await send(.operationResult(.failure(error)))
                }

            case .operationResult(.success(let message)):
                state.statusMessage = message
                return .none

            case .operationResult(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .dismissStatus:
                state.statusMessage = nil
                return .none

            case .toggleSystemApps:
                state.showSystemApps.toggle()
                return .send(.loadApps)
            }
        }
    }
}
