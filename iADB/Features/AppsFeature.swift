import Foundation
import ComposableArchitecture

@Reducer
struct AppsFeature {
    enum OperationKind: String, Equatable {
        case uninstall = "Uninstalling"
        case forceStop = "Force stopping"
        case clearData = "Clearing data for"
        case launch = "Launching"
    }

    struct ActiveOperation: Equatable {
        var id: UUID
        var packageName: String
        var kind: OperationKind

        var message: String { "\(kind.rawValue) \(packageName)..." }
    }

    enum AppFilter: String, CaseIterable, Equatable {
        case user = "User"
        case system = "System"
        case all = "All"
    }

    enum AppSort: String, CaseIterable, Equatable {
        case name = "Name"
        case package = "Package"
    }

    @ObservableState
    struct State: Equatable {
        var apps: [AppInfo] = []
        var isLoading = false
        var errorMessage: String?
        var statusMessage: String?
        var showSystemApps = false
        var filter: AppFilter = .user
        var sort: AppSort = .name
        var searchText = ""
        var selectedApp: AppInfo?
        var appDetail: AppDetail?
        var showingAppDetail = false
        var appDetailText = ""
        var isLoadingDetail = false
        var activeAppDetailID: UUID?
        var activeAppDetailPackageName: String?
        var isInstalling = false
        var installProgress = ""
        var activeInstallID: UUID?
        var activeInstallRemotePath: String?
        var activeOperation: ActiveOperation?

        var filteredApps: [AppInfo] {
            let visibilityFiltered = apps.filter { app in
                switch filter {
                case .user: return !app.isSystemApp
                case .system: return app.isSystemApp
                case .all: return true
                }
            }

            let searched = searchText.isEmpty
                ? visibilityFiltered
                : visibilityFiltered.filter {
                    $0.packageName.localizedCaseInsensitiveContains(searchText) ||
                    ($0.appName?.localizedCaseInsensitiveContains(searchText) ?? false)
                }

            return searched.sorted { lhs, rhs in
                switch sort {
                case .name:
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case .package:
                    return lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
                }
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
        case installAPKFile(url: URL, fileName: String)
        case installProgressChanged(id: UUID, message: String)
        case installSucceeded(id: UUID, result: String)
        case installFailed(id: UUID, message: String)
        case cancelInstall
        case importFailed(String)
        case launchApp(AppInfo)
        case operationSucceeded(id: UUID, message: String, reloadApps: Bool)
        case operationFailed(id: UUID, message: String)
        case cancelOperation
        case cancelAll
        case appDetailLoaded(id: UUID, packageName: String, Result<String, Error>)
        case dismissStatus
        case dismissError
        case setFilter(AppFilter)
        case setSort(AppSort)
        case toggleSystemApps
    }

    private enum CancelID { case loadApps, operation, appDetail, install }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .loadApps:
                guard !state.isLoading, state.activeOperation == nil, !state.isInstalling else { return .none }
                state.isLoading = true
                state.errorMessage = nil

                return .run { send in
                    async let allPackages = adbClient.listPackages(true)
                    async let userPackages = adbClient.listPackages(false)
                    let all = try await allPackages
                    let user = Set(try await userPackages)
                    let apps = all.map { pkg in
                        AppInfo(packageName: pkg, isSystemApp: !user.contains(pkg))
                    }
                    await send(.appsLoaded(.success(apps)))
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
                guard state.activeOperation == nil, !state.isInstalling else { return .none }
                let operationID = uuid()
                state.activeOperation = ActiveOperation(id: operationID, packageName: app.packageName, kind: .uninstall)
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    let result = try await adbClient.uninstallPackage(app.packageName, keepData)
                    await send(.operationSucceeded(id: operationID, message: result, reloadApps: true))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation, cancelInFlight: false)

            case .forceStop(let app):
                guard state.activeOperation == nil, !state.isInstalling else { return .none }
                let operationID = uuid()
                state.activeOperation = ActiveOperation(id: operationID, packageName: app.packageName, kind: .forceStop)
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    try await adbClient.forceStopApp(app.packageName)
                    await send(.operationSucceeded(id: operationID, message: "Force stopped \(app.packageName)", reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation, cancelInFlight: false)

            case .clearData(let app):
                guard state.activeOperation == nil, !state.isInstalling else { return .none }
                let operationID = uuid()
                state.activeOperation = ActiveOperation(id: operationID, packageName: app.packageName, kind: .clearData)
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    let result = try await adbClient.clearAppData(app.packageName)
                    await send(.operationSucceeded(id: operationID, message: result, reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation, cancelInFlight: false)

            case .getAppDetail(let app):
                let detailID = uuid()
                state.selectedApp = app
                state.appDetail = nil
                state.appDetailText = ""
                state.isLoadingDetail = true
                state.activeAppDetailID = detailID
                state.activeAppDetailPackageName = app.packageName
                state.errorMessage = nil
                return .run { send in
                    let detail = try await adbClient.getAppInfo(app.packageName)
                    await send(.appDetailLoaded(
                        id: detailID,
                        packageName: app.packageName,
                        .success(detail)
                    ))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.appDetailLoaded(
                        id: detailID,
                        packageName: app.packageName,
                        .failure(error)
                    ))
                }
                .cancellable(id: CancelID.appDetail, cancelInFlight: true)

            case .appDetailLoaded(let id, let packageName, .success(let detail)):
                guard state.activeAppDetailID == id,
                      state.activeAppDetailPackageName == packageName,
                      state.selectedApp?.packageName == packageName else { return .none }
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.appDetailText = detail
                if let app = state.selectedApp {
                    state.appDetail = AppDetail.parse(packageName: app.packageName, rawText: detail)
                }
                state.showingAppDetail = true
                return .none

            case .appDetailLoaded(let id, let packageName, .failure(let error)):
                guard state.activeAppDetailID == id,
                      state.activeAppDetailPackageName == packageName else { return .none }
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.errorMessage = error.localizedDescription
                return .none

            case .installAPK(let data, let fileName):
                guard !state.isInstalling, state.activeOperation == nil else { return .none }
                let installID = uuid()
                let remotePath = Self.installRemotePath(id: installID)
                state.isInstalling = true
                state.installProgress = "Pushing \(fileName) to device..."
                state.errorMessage = nil
                state.activeInstallID = installID
                state.activeInstallRemotePath = remotePath

                return .run { send in
                    try await adbClient.pushData(data, remotePath, 0o644)
                    await send(.installProgressChanged(id: installID, message: "Installing APK..."))
                    let result = try await adbClient.shell("pm install -r '\(remotePath)'")
                    _ = try? await adbClient.shell("rm -f '\(remotePath)'")
                    await send(.installSucceeded(id: installID, result: result))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                    guard !(error is CancellationError) else { return }
                    await send(.installFailed(id: installID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.install, cancelInFlight: true)

            case .installAPKFile(let url, let fileName):
                guard !state.isInstalling, state.activeOperation == nil else { return .none }
                let installID = uuid()
                let remotePath = Self.installRemotePath(id: installID)
                state.isInstalling = true
                state.installProgress = "Pushing \(fileName) to device..."
                state.errorMessage = nil
                state.activeInstallID = installID
                state.activeInstallRemotePath = remotePath

                return .run { send in
                    let isSecurityScoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                    }
                    try await adbClient.pushFile(url, remotePath, 0o644)
                    await send(.installProgressChanged(id: installID, message: "Installing APK..."))
                    let result = try await adbClient.shell("pm install -r '\(remotePath)'")
                    _ = try? await adbClient.shell("rm -f '\(remotePath)'")
                    await send(.installSucceeded(id: installID, result: result))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                    guard !(error is CancellationError) else { return }
                    await send(.installFailed(id: installID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.install, cancelInFlight: true)

            case .installProgressChanged(let id, let message):
                guard state.isInstalling, state.activeInstallID == id else { return .none }
                state.installProgress = message
                return .none

            case .installSucceeded(let id, let result):
                guard state.activeInstallID == id else { return .none }
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                state.statusMessage = result
                return .send(.loadApps)

            case .installFailed(let id, let message):
                guard state.activeInstallID == id else { return .none }
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                state.errorMessage = message
                return .none

            case .cancelInstall:
                guard state.isInstalling else { return .none }
                let remotePath = state.activeInstallRemotePath
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                return .merge(
                    .cancel(id: CancelID.install),
                    .run { _ in
                        if let remotePath {
                            _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                        }
                    }
                )

            case .importFailed(let message):
                state.errorMessage = message
                return .none

            case .launchApp(let app):
                guard state.activeOperation == nil, !state.isInstalling else { return .none }
                let operationID = uuid()
                state.activeOperation = ActiveOperation(id: operationID, packageName: app.packageName, kind: .launch)
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    _ = try await adbClient.shell("monkey -p \(adbShellQuote(app.packageName)) -c android.intent.category.LAUNCHER 1")
                    await send(.operationSucceeded(id: operationID, message: "Launched \(app.packageName)", reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation, cancelInFlight: false)

            case .operationSucceeded(let id, let message, let reloadApps):
                guard state.activeOperation?.id == id else { return .none }
                state.activeOperation = nil
                state.statusMessage = message
                return reloadApps ? .send(.loadApps) : .none

            case .operationFailed(let id, let message):
                guard state.activeOperation?.id == id else { return .none }
                state.activeOperation = nil
                state.errorMessage = message
                return .none

            case .cancelOperation:
                guard state.activeOperation != nil else { return .none }
                state.activeOperation = nil
                return .cancel(id: CancelID.operation)

            case .cancelAll:
                let installPath = state.activeInstallRemotePath
                state.isLoading = false
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                state.activeOperation = nil
                return .merge(
                    .cancel(id: CancelID.loadApps),
                    .cancel(id: CancelID.operation),
                    .cancel(id: CancelID.appDetail),
                    .cancel(id: CancelID.install),
                    .run { _ in
                        if let installPath {
                            _ = try? await adbClient.shell("rm -f \(adbShellQuote(installPath))")
                        }
                    }
                )

            case .dismissStatus:
                state.statusMessage = nil
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none

            case .setFilter(let filter):
                state.filter = filter
                state.showSystemApps = filter != .user
                return .none

            case .setSort(let sort):
                state.sort = sort
                return .none

            case .toggleSystemApps:
                state.showSystemApps.toggle()
                state.filter = state.showSystemApps ? .all : .user
                return .none
            }
        }
    }

    private static func installRemotePath(id: UUID) -> String {
        "/data/local/tmp/iadb-upload-\(id.uuidString).apk"
    }
}
