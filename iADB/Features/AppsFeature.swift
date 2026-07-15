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

        var message: String {
            switch kind {
            case .uninstall: String(localized: "Uninstalling \(packageName)...")
            case .forceStop: String(localized: "Force stopping \(packageName)...")
            case .clearData: String(localized: "Clearing data for \(packageName)...")
            case .launch: String(localized: "Launching \(packageName)...")
            }
        }
    }

    struct ListSnapshotMetadata: Equatable {
        var deviceID: String
        var fetchedAt: Date
    }

    struct InstallReview: Equatable, Identifiable {
        let id: UUID
        let localURL: URL
        let fileName: String
        let totalBytes: Int64?
        let target: RemoteDeviceTarget
        var replaceExisting = true
        var grantRuntimePermissions = false
        var allowTestPackages = false
    }

    struct BulkUninstallState: Equatable, Identifiable {
        struct Item: Equatable, Identifiable {
            enum Phase: Equatable {
                case pending
                case running
                case succeeded
                case failed(String)
            }

            let app: AppInfo
            var phase: Phase = .pending
            var id: String { app.packageName }
        }

        let id: UUID
        var items: [Item]

        var succeededCount: Int { items.count { $0.phase == .succeeded } }
        var failedCount: Int {
            items.count { if case .failed = $0.phase { return true }; return false }
        }
        var completedCount: Int { succeededCount + failedCount }
        var isActive: Bool {
            items.contains { $0.phase == .pending || $0.phase == .running }
        }
    }

    enum AppFilter: String, CaseIterable, Equatable {
        case user = "User"
        case system = "System"
        case all = "All"

        var localizedTitle: String {
            switch self {
            case .user: String(localized: "User")
            case .system: String(localized: "System")
            case .all: String(localized: "All")
            }
        }
    }

    enum AppSort: String, CaseIterable, Equatable {
        case name = "Name"
        case package = "Package"

        var localizedTitle: String {
            switch self {
            case .name: String(localized: "Name")
            case .package: String(localized: "Package")
            }
        }
    }

    @ObservableState
    struct State: Equatable {
        var remoteTarget = RemoteDeviceTarget.unavailable
        var apps: [AppInfo] = []
        var isLoading = false
        var listGeneration = 0
        var activeListGeneration: Int?
        var listSnapshot: ListSnapshotMetadata?
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
        var activeAppDetailDeviceID: String?
        var isInstalling = false
        var installReview: InstallReview?
        var installProgress = ""
        var activeInstallID: UUID?
        var activeInstallRemotePath: String?
        var operationsByPackage: [String: ActiveOperation] = [:]
        var isSelectionMode = false
        var selectedPackageNames: Set<String> = []
        var bulkUninstall: BulkUninstallState?
        var bulkResultSummary: String?

        var hasActiveOperations: Bool { !operationsByPackage.isEmpty }
        var activeOperation: ActiveOperation? {
            get { operationsByPackage.values.sorted { $0.packageName < $1.packageName }.first }
            set {
                operationsByPackage.removeAll()
                if let newValue {
                    operationsByPackage[newValue.packageName] = newValue
                }
            }
        }

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
        case appsLoaded(
            generation: Int,
            deviceID: String,
            fetchedAt: Date,
            Result<[AppInfo], Error>
        )
        case uninstall(AppInfo, keepData: Bool, confirmation: DestructiveActionConfirmation?)
        case forceStop(AppInfo)
        case clearData(AppInfo, confirmation: DestructiveActionConfirmation?)
        case getAppDetail(AppInfo)
        case selectInspector(AppInfo?)
        case installAPK(data: Data, fileName: String)
        case reviewAPKFile(url: URL, fileName: String, totalBytes: Int64?)
        case setInstallReplaceExisting(Bool)
        case setInstallGrantRuntimePermissions(Bool)
        case setInstallAllowTestPackages(Bool)
        case dismissInstallReview
        case confirmInstallReview
        case installAPKFile(url: URL, fileName: String)
        case installAPKFileWithOptions(
            url: URL,
            fileName: String,
            replaceExisting: Bool,
            grantRuntimePermissions: Bool,
            allowTestPackages: Bool
        )
        case installProgressChanged(id: UUID, message: String)
        case installSucceeded(id: UUID, result: String)
        case installFailed(id: UUID, message: String)
        case installCleanupCompleted(id: UUID, Result<Bool, EquatableError>)
        case cancelInstall
        case importFailed(String)
        case launchApp(AppInfo)
        case operationSucceeded(id: UUID, message: String, reloadApps: Bool)
        case operationFailed(id: UUID, message: String)
        case cancelOperation(packageName: String)
        case toggleSelectionMode
        case togglePackageSelection(AppInfo)
        case selectAllVisible([AppInfo])
        case clearSelection
        case uninstallSelected(confirmation: DestructiveActionConfirmation?)
        case bulkUninstallItemStarted(packageName: String)
        case bulkUninstallItemCompleted(packageName: String, Result<Void, EquatableError>)
        case bulkUninstallCompleted(id: UUID)
        case cancelBulkUninstall
        case cancelAll
        case appDetailLoaded(
            id: UUID,
            packageName: String,
            deviceID: String,
            showsSheet: Bool,
            Result<String, Error>
        )
        case dismissStatus
        case dismissError
        case setFilter(AppFilter)
        case setSort(AppSort)
        case toggleSystemApps
        case delegate(Delegate)

        enum Delegate: Equatable {
            case operationStarted(BackgroundOperation)
            case operationPhase(id: UUID, phase: BackgroundOperation.Phase, detail: String?)
            case operationFinished(id: UUID, outcome: BackgroundOperation.Outcome, date: Date)
            case cleanupCompleted(id: UUID, Result<Bool, EquatableError>)
        }
    }

    private enum CancelID: Hashable {
        case loadApps
        case operation(String)
        case appDetail
        case install
        case bulkUninstall
    }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce<State, Action> { state, action in
            switch action {
            case .binding:
                return .none

            case .loadApps:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.listGeneration += 1
                let generation = state.listGeneration
                let deviceID = state.remoteTarget.deviceID
                state.activeListGeneration = generation
                state.errorMessage = nil
                PerformanceSignposts.appList("start")

                return .run { send in
                    async let allPackages = adbClient.listPackages(true)
                    async let userPackages = adbClient.listPackages(false)
                    let all = try await allPackages
                    let user = Set(try await userPackages)
                    let apps = all.map { pkg in
                        AppInfo(packageName: pkg, isSystemApp: !user.contains(pkg))
                    }
                    await send(.appsLoaded(
                        generation: generation,
                        deviceID: deviceID,
                        fetchedAt: date.now,
                        .success(apps)
                    ))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.appsLoaded(
                        generation: generation,
                        deviceID: deviceID,
                        fetchedAt: date.now,
                        .failure(error)
                    ))
                }
                .cancellable(id: CancelID.loadApps, cancelInFlight: true)

            case .appsLoaded(let generation, let deviceID, let fetchedAt, .success(let apps)):
                guard state.activeListGeneration == generation,
                      state.remoteTarget.deviceID == deviceID else { return .none }
                state.isLoading = false
                state.activeListGeneration = nil
                state.apps = apps
                state.listSnapshot = ListSnapshotMetadata(deviceID: deviceID, fetchedAt: fetchedAt)
                if let selectedPackage = state.selectedApp?.packageName,
                   let refreshedSelection = apps.first(where: { $0.packageName == selectedPackage }) {
                    state.selectedApp = refreshedSelection
                }
                PerformanceSignposts.appList("success", packageCount: apps.count)
                return .none

            case .appsLoaded(let generation, let deviceID, _, .failure(let error)):
                guard state.activeListGeneration == generation,
                      state.remoteTarget.deviceID == deviceID else { return .none }
                state.isLoading = false
                state.activeListGeneration = nil
                state.errorMessage = error.localizedDescription
                PerformanceSignposts.appList("failed")
                return .none

            case .uninstall(let app, let keepData, let confirmation):
                guard let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: app.packageName) else {
                    state.errorMessage = String(localized: "The target device changed. Confirm uninstall again on the connected device.")
                    return .none
                }
                guard state.operationsByPackage[app.packageName] == nil else { return .none }
                let operationID = uuid()
                state.operationsByPackage[app.packageName] = ActiveOperation(
                    id: operationID,
                    packageName: app.packageName,
                    kind: .uninstall
                )
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    let result = try await adbClient.uninstallPackage(app.packageName, keepData)
                    await send(.operationSucceeded(id: operationID, message: result, reloadApps: true))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation(app.packageName), cancelInFlight: false)

            case .forceStop(let app):
                guard state.operationsByPackage[app.packageName] == nil else { return .none }
                let operationID = uuid()
                state.operationsByPackage[app.packageName] = ActiveOperation(
                    id: operationID,
                    packageName: app.packageName,
                    kind: .forceStop
                )
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    try await adbClient.forceStopApp(app.packageName)
                    await send(.operationSucceeded(id: operationID, message: String(localized: "Force stopped \(app.packageName)"), reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation(app.packageName), cancelInFlight: false)

            case .clearData(let app, let confirmation):
                guard let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: app.packageName) else {
                    state.errorMessage = String(localized: "The target device changed. Confirm Clear Data again on the connected device.")
                    return .none
                }
                guard state.operationsByPackage[app.packageName] == nil else { return .none }
                let operationID = uuid()
                state.operationsByPackage[app.packageName] = ActiveOperation(
                    id: operationID,
                    packageName: app.packageName,
                    kind: .clearData
                )
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    let result = try await adbClient.clearAppData(app.packageName)
                    await send(.operationSucceeded(id: operationID, message: result, reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation(app.packageName), cancelInFlight: false)

            case .getAppDetail(let app):
                return startDetailLoad(state: &state, app: app, showsSheet: true)

            case .selectInspector(let app):
                guard let app else {
                    state.selectedApp = nil
                    state.appDetail = nil
                    state.appDetailText = ""
                    state.isLoadingDetail = false
                    state.activeAppDetailID = nil
                    state.activeAppDetailPackageName = nil
                    state.activeAppDetailDeviceID = nil
                    return .cancel(id: CancelID.appDetail)
                }
                return startDetailLoad(state: &state, app: app, showsSheet: false)

            case .appDetailLoaded(let id, let packageName, let deviceID, let showsSheet, .success(let detail)):
                guard state.activeAppDetailID == id,
                      state.activeAppDetailPackageName == packageName,
                      state.activeAppDetailDeviceID == deviceID,
                      state.remoteTarget.deviceID == deviceID,
                      state.selectedApp?.packageName == packageName else { return .none }
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.activeAppDetailDeviceID = nil
                state.appDetailText = detail
                if let app = state.selectedApp {
                    state.appDetail = AppDetail.parse(packageName: app.packageName, rawText: detail)
                }
                state.showingAppDetail = showsSheet
                return .none

            case .appDetailLoaded(let id, let packageName, let deviceID, _, .failure(let error)):
                guard state.activeAppDetailID == id,
                      state.activeAppDetailPackageName == packageName,
                      state.activeAppDetailDeviceID == deviceID,
                      state.remoteTarget.deviceID == deviceID else { return .none }
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.activeAppDetailDeviceID = nil
                state.errorMessage = error.localizedDescription
                return .none

            case .reviewAPKFile(let url, let fileName, let totalBytes):
                guard !state.isInstalling else { return .none }
                state.installReview = InstallReview(
                    id: uuid(),
                    localURL: url,
                    fileName: fileName,
                    totalBytes: totalBytes,
                    target: state.remoteTarget
                )
                state.errorMessage = nil
                return .none

            case .setInstallReplaceExisting(let isEnabled):
                state.installReview?.replaceExisting = isEnabled
                return .none

            case .setInstallGrantRuntimePermissions(let isEnabled):
                state.installReview?.grantRuntimePermissions = isEnabled
                return .none

            case .setInstallAllowTestPackages(let isEnabled):
                state.installReview?.allowTestPackages = isEnabled
                return .none

            case .dismissInstallReview:
                state.installReview = nil
                return .none

            case .confirmInstallReview:
                guard let review = state.installReview,
                      review.target == state.remoteTarget,
                      review.target.isConnected else {
                    state.installReview = nil
                    state.errorMessage = String(localized: "The target device changed. Review the APK again before installing.")
                    return .none
                }
                state.installReview = nil
                return .send(.installAPKFileWithOptions(
                    url: review.localURL,
                    fileName: review.fileName,
                    replaceExisting: review.replaceExisting,
                    grantRuntimePermissions: review.grantRuntimePermissions,
                    allowTestPackages: review.allowTestPackages
                ))

            case .installAPK(let data, let fileName):
                guard !state.isInstalling else { return .none }
                let installID = uuid()
                let remotePath = Self.installRemotePath(id: installID)
                state.isInstalling = true
                state.installProgress = String(localized: "Pushing \(fileName) to device...")
                state.errorMessage = nil
                state.activeInstallID = installID
                state.activeInstallRemotePath = remotePath

                let operation = installOperation(
                    id: installID,
                    fileName: fileName,
                    target: state.remoteTarget,
                    startedAt: date.now
                )
                let installEffect: Effect<Action> = .run { send in
                    try await adbClient.pushData(data, remotePath, 0o644)
                    await send(.installProgressChanged(id: installID, message: String(localized: "Installing APK...")))
                    let result = try await adbClient.shell("pm install -r '\(remotePath)'")
                    _ = try? await adbClient.shell("rm -f '\(remotePath)'")
                    await send(.installSucceeded(id: installID, result: result))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                    guard !(error is CancellationError) else { return }
                    await send(.installFailed(id: installID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.install, cancelInFlight: true)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    installEffect
                )

            case .installAPKFile(let url, let fileName):
                return startFileInstall(
                    state: &state,
                    url: url,
                    fileName: fileName,
                    replaceExisting: true,
                    grantRuntimePermissions: false,
                    allowTestPackages: false
                )

            case .installAPKFileWithOptions(
                let url,
                let fileName,
                let replaceExisting,
                let grantRuntimePermissions,
                let allowTestPackages
            ):
                return startFileInstall(
                    state: &state,
                    url: url,
                    fileName: fileName,
                    replaceExisting: replaceExisting,
                    grantRuntimePermissions: grantRuntimePermissions,
                    allowTestPackages: allowTestPackages
                )

            case .installProgressChanged(let id, let message):
                guard state.isInstalling, state.activeInstallID == id else { return .none }
                state.installProgress = message
                return .send(.delegate(.operationPhase(
                    id: id,
                    phase: .running,
                    detail: message
                )))

            case .installSucceeded(let id, let result):
                guard state.activeInstallID == id else { return .none }
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                state.statusMessage = result
                return .merge(
                    .send(.delegate(.operationFinished(
                        id: id,
                        outcome: .success(summary: result),
                        date: date.now
                    ))),
                    .send(.loadApps)
                )

            case .installFailed(let id, let message):
                guard state.activeInstallID == id else { return .none }
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                state.errorMessage = message
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: .failure(message: message, retryable: false),
                    date: date.now
                )))

            case .installCleanupCompleted(let id, let result):
                return .send(.delegate(.cleanupCompleted(id: id, result)))

            case .cancelInstall:
                guard state.isInstalling else { return .none }
                let installID = state.activeInstallID
                let remotePath = state.activeInstallRemotePath
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                return .merge(
                    .cancel(id: CancelID.install),
                    .run { send in
                        guard let installID else { return }
                        guard let remotePath else {
                            await send(.installCleanupCompleted(id: installID, .success(false)))
                            return
                        }
                        do {
                            _ = try await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                            await send(.installCleanupCompleted(id: installID, .success(true)))
                        } catch {
                            await send(.installCleanupCompleted(
                                id: installID,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                )

            case .importFailed(let message):
                state.errorMessage = message
                return .none

            case .launchApp(let app):
                guard state.operationsByPackage[app.packageName] == nil else { return .none }
                let operationID = uuid()
                state.operationsByPackage[app.packageName] = ActiveOperation(
                    id: operationID,
                    packageName: app.packageName,
                    kind: .launch
                )
                state.statusMessage = nil
                state.errorMessage = nil
                return .run { send in
                    _ = try await adbClient.shell("monkey -p \(adbShellQuote(app.packageName)) -c android.intent.category.LAUNCHER 1")
                    await send(.operationSucceeded(id: operationID, message: String(localized: "Launched \(app.packageName)"), reloadApps: false))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationFailed(id: operationID, message: error.localizedDescription))
                }
                .cancellable(id: CancelID.operation(app.packageName), cancelInFlight: false)

            case .operationSucceeded(let id, let message, let reloadApps):
                guard let packageName = state.operationsByPackage.first(where: { $0.value.id == id })?.key else {
                    return .none
                }
                state.operationsByPackage[packageName] = nil
                state.statusMessage = message
                return reloadApps ? .send(.loadApps) : .none

            case .operationFailed(let id, let message):
                guard let packageName = state.operationsByPackage.first(where: { $0.value.id == id })?.key else {
                    return .none
                }
                state.operationsByPackage[packageName] = nil
                state.errorMessage = message
                return .none

            case .cancelOperation(let packageName):
                guard state.operationsByPackage.removeValue(forKey: packageName) != nil else { return .none }
                return .cancel(id: CancelID.operation(packageName))

            case .toggleSelectionMode:
                state.isSelectionMode.toggle()
                if !state.isSelectionMode { state.selectedPackageNames.removeAll() }
                return .none

            case .togglePackageSelection(let app):
                guard !app.isSystemApp else {
                    state.errorMessage = String(localized: "System apps are excluded from bulk uninstall.")
                    return .none
                }
                state.isSelectionMode = true
                if state.selectedPackageNames.contains(app.packageName) {
                    state.selectedPackageNames.remove(app.packageName)
                } else {
                    state.selectedPackageNames.insert(app.packageName)
                }
                return .none

            case .selectAllVisible(let apps):
                state.isSelectionMode = true
                state.selectedPackageNames.formUnion(
                    apps.lazy.filter { !$0.isSystemApp }.map(\.packageName)
                )
                return .none

            case .clearSelection:
                state.isSelectionMode = false
                state.selectedPackageNames.removeAll()
                return .none

            case .uninstallSelected(let confirmation):
                let apps = state.apps.filter {
                    state.selectedPackageNames.contains($0.packageName) && !$0.isSystemApp
                }
                let objectID = Self.bulkUninstallObjectID(packages: apps.map(\.packageName))
                guard !apps.isEmpty,
                      let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: objectID),
                      state.bulkUninstall?.isActive != true else {
                    state.errorMessage = String(localized: "The target device changed. Confirm bulk uninstall again on the connected device.")
                    return .none
                }
                let operationID = uuid()
                state.bulkUninstall = BulkUninstallState(
                    id: operationID,
                    items: apps.map { BulkUninstallState.Item(app: $0) }
                )
                state.bulkResultSummary = nil
                state.errorMessage = nil
                let operation = BackgroundOperation(
                    id: operationID,
                    deviceID: state.remoteTarget.deviceID,
                    deviceName: state.remoteTarget.deviceName,
                    workspace: .apps,
                    kind: .appMutation,
                    objectName: "\(apps.count) apps",
                    phase: .preparing,
                    completedUnits: 0,
                    totalUnits: Int64(apps.count),
                    detail: String(localized: "Uninstalling selected user apps…"),
                    isCancellable: true,
                    isTransportDependent: true,
                    cleanupState: .notRequired,
                    outcome: nil,
                    retryPayload: nil,
                    startedAt: date.now,
                    finishedAt: nil
                )
                let effect: Effect<Action> = .run { send in
                    for app in apps {
                        try Task.checkCancellation()
                        await send(.bulkUninstallItemStarted(packageName: app.packageName))
                        do {
                            _ = try await adbClient.uninstallPackage(app.packageName, false)
                            await send(.bulkUninstallItemCompleted(
                                packageName: app.packageName,
                                .success(())
                            ))
                        } catch {
                            guard !(error is CancellationError) else { throw error }
                            await send(.bulkUninstallItemCompleted(
                                packageName: app.packageName,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                    await send(.bulkUninstallCompleted(id: operationID))
                }
                .cancellable(id: CancelID.bulkUninstall, cancelInFlight: true)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    effect
                )

            case .bulkUninstallItemStarted(let packageName):
                guard let index = state.bulkUninstall?.items.firstIndex(where: { $0.id == packageName }) else {
                    return .none
                }
                state.bulkUninstall?.items[index].phase = .running
                return .none

            case .bulkUninstallItemCompleted(let packageName, let result):
                guard let index = state.bulkUninstall?.items.firstIndex(where: { $0.id == packageName }),
                      let operationID = state.bulkUninstall?.id else { return .none }
                switch result {
                case .success:
                    state.bulkUninstall?.items[index].phase = .succeeded
                    state.selectedPackageNames.remove(packageName)
                case .failure(let error):
                    state.bulkUninstall?.items[index].phase = .failed(error.message)
                }
                let completed = state.bulkUninstall?.completedCount ?? 0
                return .send(.delegate(.operationPhase(
                    id: operationID,
                    phase: .running,
                    detail: String(localized: "Processed \(completed) of \(state.bulkUninstall?.items.count ?? 0) apps")
                )))

            case .bulkUninstallCompleted(let id):
                guard state.bulkUninstall?.id == id, let bulk = state.bulkUninstall else { return .none }
                state.bulkResultSummary = String(
                    localized: "\(bulk.succeededCount) succeeded, \(bulk.failedCount) failed"
                )
                let outcome: BackgroundOperation.Outcome = bulk.failedCount == 0
                    ? .success(summary: state.bulkResultSummary ?? String(localized: "Uninstall complete"))
                    : .failure(message: state.bulkResultSummary ?? String(localized: "Some apps could not be uninstalled"), retryable: false)
                return .merge(
                    .send(.delegate(.operationFinished(id: id, outcome: outcome, date: date.now))),
                    .send(.loadApps)
                )

            case .cancelBulkUninstall:
                guard var bulk = state.bulkUninstall else { return .none }
                for index in bulk.items.indices {
                    if bulk.items[index].phase == .pending || bulk.items[index].phase == .running {
                        bulk.items[index].phase = .failed(String(localized: "Cancelled"))
                    }
                }
                state.bulkUninstall = bulk
                state.bulkResultSummary = String(
                    localized: "\(bulk.succeededCount) succeeded, \(bulk.failedCount) failed"
                )
                return .merge(
                    .cancel(id: CancelID.bulkUninstall),
                    .send(.delegate(.operationFinished(
                        id: bulk.id,
                        outcome: .cancelled,
                        date: date.now
                    )))
                )

            case .cancelAll:
                let installPath = state.activeInstallRemotePath
                state.isLoading = false
                state.activeListGeneration = nil
                state.isLoadingDetail = false
                state.activeAppDetailID = nil
                state.activeAppDetailPackageName = nil
                state.activeAppDetailDeviceID = nil
                state.isInstalling = false
                state.installProgress = ""
                state.activeInstallID = nil
                state.activeInstallRemotePath = nil
                let activePackages = Array(state.operationsByPackage.keys)
                state.operationsByPackage.removeAll()
                if var bulk = state.bulkUninstall {
                    for index in bulk.items.indices {
                        if bulk.items[index].phase == .pending || bulk.items[index].phase == .running {
                            bulk.items[index].phase = .failed(String(localized: "Disconnected before completion"))
                        }
                    }
                    state.bulkUninstall = bulk
                    state.bulkResultSummary = String(
                        localized: "\(bulk.succeededCount) succeeded, \(bulk.failedCount) failed"
                    )
                }
                return .merge(
                    .cancel(id: CancelID.loadApps),
                    .cancel(id: CancelID.appDetail),
                    .cancel(id: CancelID.install),
                    .cancel(id: CancelID.bulkUninstall),
                    .merge(activePackages.map { .cancel(id: CancelID.operation($0)) }),
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

            case .delegate:
                return .none
            }
        }
    }

    private func startDetailLoad(
        state: inout State,
        app: AppInfo,
        showsSheet: Bool
    ) -> Effect<Action> {
        let detailID = uuid()
        let deviceID = state.remoteTarget.deviceID
        state.selectedApp = app
        state.appDetail = nil
        state.appDetailText = ""
        state.isLoadingDetail = true
        state.activeAppDetailID = detailID
        state.activeAppDetailPackageName = app.packageName
        state.activeAppDetailDeviceID = deviceID
        state.errorMessage = nil
        return .run { send in
            let detail = try await adbClient.getAppInfo(app.packageName)
            await send(.appDetailLoaded(
                id: detailID,
                packageName: app.packageName,
                deviceID: deviceID,
                showsSheet: showsSheet,
                .success(detail)
            ))
        } catch: { error, send in
            guard !(error is CancellationError) else { return }
            await send(.appDetailLoaded(
                id: detailID,
                packageName: app.packageName,
                deviceID: deviceID,
                showsSheet: showsSheet,
                .failure(error)
            ))
        }
        .cancellable(id: CancelID.appDetail, cancelInFlight: true)
    }

    private func startFileInstall(
        state: inout State,
        url: URL,
        fileName: String,
        replaceExisting: Bool,
        grantRuntimePermissions: Bool,
        allowTestPackages: Bool
    ) -> Effect<Action> {
        guard !state.isInstalling else { return .none }
        let installID = uuid()
        let remotePath = Self.installRemotePath(id: installID)
        state.isInstalling = true
        state.installProgress = String(localized: "Pushing \(fileName) to device...")
        state.errorMessage = nil
        state.activeInstallID = installID
        state.activeInstallRemotePath = remotePath

        let operation = installOperation(
            id: installID,
            fileName: fileName,
            target: state.remoteTarget,
            startedAt: date.now
        )
        let installEffect: Effect<Action> = .run { send in
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            }
            try await adbClient.pushFile(url, remotePath, 0o644)
            await send(.installProgressChanged(id: installID, message: String(localized: "Installing APK...")))
            var flags: [String] = []
            if replaceExisting { flags.append("-r") }
            if grantRuntimePermissions { flags.append("-g") }
            if allowTestPackages { flags.append("-t") }
            let flagString = flags.isEmpty ? "" : " " + flags.joined(separator: " ")
            let result = try await adbClient.shell(
                "pm install\(flagString) \(adbShellQuote(remotePath))"
            )
            _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
            await send(.installSucceeded(id: installID, result: result))
        } catch: { error, send in
            _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
            guard !(error is CancellationError) else { return }
            await send(.installFailed(id: installID, message: error.localizedDescription))
        }
        .cancellable(id: CancelID.install, cancelInFlight: true)
        return .concatenate(
            .send(.delegate(.operationStarted(operation))),
            installEffect
        )
    }

    private func installOperation(
        id: UUID,
        fileName: String,
        target: RemoteDeviceTarget,
        startedAt: Date
    ) -> BackgroundOperation {
        BackgroundOperation(
            id: id,
            deviceID: target.deviceID,
            deviceName: target.deviceName,
            workspace: .apps,
            kind: .installAPK,
            objectName: fileName,
            phase: .preparing,
            completedUnits: nil,
            totalUnits: nil,
            detail: String(localized: "Uploading APK to the target device…"),
            isCancellable: true,
            isTransportDependent: true,
            cleanupState: .notRequired,
            outcome: nil,
            retryPayload: nil,
            startedAt: startedAt,
            finishedAt: nil
        )
    }

    private static func installRemotePath(id: UUID) -> String {
        "/data/local/tmp/iadb-upload-\(id.uuidString).apk"
    }

    static func bulkUninstallObjectID(packages: [String]) -> String {
        "bulk-uninstall:" + packages.sorted().joined(separator: "|")
    }
}
