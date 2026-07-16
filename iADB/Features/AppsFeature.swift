import ComposableArchitecture
import Foundation

@Reducer
struct AppsFeature {
    @ObservableState
    struct State: Equatable {
        var apps: [AppInfo] = []
        var isConnected = false
        var isLoading = false
        var isMutating = false
        var isInstalling = false
        var errorMessage: String?
    }

    enum Action {
        case setConnected(Bool)
        case load
        case loaded(Result<[String], Error>)
        case uninstall(String)
        case forceStop(String)
        case clearData(String)
        case launch(String)
        case mutationFinished(package: String, removesPackage: Bool, Result<Void, Error>)
        case install(URL)
        case installFinished(Result<Void, Error>)
        case cancel
    }

    private enum CancelID { case request }
    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setConnected(let value):
                state.isConnected = value
                return value ? .none : .send(.cancel)

            case .load:
                guard state.isConnected else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        await send(.loaded(.success(try await adbClient.listPackages(true))))
                    } catch {
                        await send(.loaded(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .loaded(.success(let packages)):
                state.isLoading = false
                state.apps = Set(packages).sorted().map { AppInfo(packageName: $0) }
                return .none

            case .loaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .uninstall(let package):
                return mutate(&state, package: package, removesPackage: true) {
                    _ = try await adbClient.uninstallPackage(package, false)
                }

            case .forceStop(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    try await adbClient.forceStopApp(package)
                }

            case .clearData(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    _ = try await adbClient.clearAppData(package)
                }

            case .launch(let package):
                return mutate(&state, package: package, removesPackage: false) {
                    _ = try await adbClient.shell("monkey -p \(adbShellQuote(package)) 1")
                }

            case .mutationFinished(let package, let removesPackage, .success):
                state.isMutating = false
                if removesPackage {
                    state.apps.removeAll { $0.packageName == package }
                }
                return .none

            case .mutationFinished(_, _, .failure(let error)):
                state.isMutating = false
                state.errorMessage = error.localizedDescription
                return .none

            case .install(let url):
                guard state.isConnected, !state.isInstalling else { return .none }
                state.isInstalling = true
                state.errorMessage = nil
                return .run { send in
                    let remotePath = "/data/local/tmp/iadb-install.apk"
                    do {
                        try await adbClient.pushFile(url, remotePath, 0o644)
                        _ = try await adbClient.shell("pm install -r \(adbShellQuote(remotePath))")
                        _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                        await send(.installFinished(.success(())))
                    } catch {
                        _ = try? await adbClient.shell("rm -f \(adbShellQuote(remotePath))")
                        await send(.installFinished(.failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .installFinished(.success):
                state.isInstalling = false
                return .send(.load)

            case .installFinished(.failure(let error)):
                state.isInstalling = false
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isLoading = false
                state.isMutating = false
                state.isInstalling = false
                return .cancel(id: CancelID.request)
            }
        }
    }

    private func mutate(
        _ state: inout State,
        package: String,
        removesPackage: Bool,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Effect<Action> {
        guard state.isConnected, !state.isMutating else { return .none }
        state.isMutating = true
        state.errorMessage = nil
        return .run { send in
            do {
                try await operation()
                await send(.mutationFinished(package: package, removesPackage: removesPackage, .success(())))
            } catch {
                await send(.mutationFinished(package: package, removesPackage: removesPackage, .failure(error)))
            }
        }
        .cancellable(id: CancelID.request, cancelInFlight: true)
    }
}
