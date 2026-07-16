import ComposableArchitecture
import Foundation

@Reducer
struct FileManagerFeature {
    @ObservableState
    struct State: Equatable {
        var currentPath = "/sdcard"
        var entries: [FileEntry] = []
        var isConnected = false
        var isLoading = false
        var isWorking = false
        var errorMessage: String?
    }

    enum Action {
        case setConnected(Bool)
        case load(String? = nil)
        case loaded(path: String, Result<[FileEntry], Error>)
        case open(FileEntry)
        case up
        case createDirectory(String)
        case createFile(name: String, data: Data)
        case delete(FileEntry)
        case rename(FileEntry, String)
        case move(FileEntry, String)
        case upload(localURL: URL, remoteName: String)
        case download(FileEntry, URL)
        case operationFinished(Result<Void, Error>)
        case downloadFinished(Result<Void, Error>)
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

            case .load(let requestedPath):
                guard state.isConnected else { return .none }
                let path = requestedPath ?? state.currentPath
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        await send(.loaded(path: path, .success(try await adbClient.listDirectoryEntries(path))))
                    } catch {
                        await send(.loaded(path: path, .failure(error)))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .loaded(let path, .success(let entries)):
                state.currentPath = path
                state.entries = entries.sorted {
                    $0.isNavigableDirectory == $1.isNavigableDirectory
                        ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        : $0.isNavigableDirectory
                }
                state.isLoading = false
                return .none

            case .loaded(_, .failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .open(let entry):
                guard entry.isNavigableDirectory else { return .none }
                return .send(.load(entry.fullPath))

            case .up:
                guard state.currentPath != "/" else { return .none }
                let parent = (state.currentPath as NSString).deletingLastPathComponent
                return .send(.load(parent.isEmpty ? "/" : parent))

            case .createDirectory(let name):
                guard Self.validName(name) else { return fail(&state, "Invalid file name") }
                let path = Self.join(state.currentPath, name)
                return operation(&state) { _ = try await adbClient.shell("mkdir \(adbShellQuote(path))") }

            case .createFile(let name, let data):
                guard Self.validName(name) else { return fail(&state, "Invalid file name") }
                let path = Self.join(state.currentPath, name)
                return operation(&state) { try await adbClient.pushData(data, path, 0o644) }

            case .delete(let entry):
                return operation(&state) {
                    _ = try await adbClient.shell("rm -rf -- \(adbShellQuote(entry.fullPath))")
                }

            case .rename(let entry, let name):
                guard Self.validName(name) else { return fail(&state, "Invalid file name") }
                let destination = Self.join(state.currentPath, name)
                return operation(&state) {
                    _ = try await adbClient.shell("mv -- \(adbShellQuote(entry.fullPath)) \(adbShellQuote(destination))")
                }

            case .move(let entry, let destination):
                guard destination.hasPrefix("/") else { return fail(&state, "Destination must be absolute") }
                return operation(&state) {
                    _ = try await adbClient.shell("mv -- \(adbShellQuote(entry.fullPath)) \(adbShellQuote(destination))")
                }

            case .upload(let localURL, let remoteName):
                guard Self.validName(remoteName) else { return fail(&state, "Invalid file name") }
                let path = Self.join(state.currentPath, remoteName)
                return operation(&state) { try await adbClient.pushFile(localURL, path, 0o644) }

            case .download(let entry, let localURL):
                return operation(&state, reload: false) {
                    try await adbClient.pullFileTo(entry.fullPath, localURL)
                }

            case .operationFinished(.success):
                state.isWorking = false
                return .send(.load())

            case .operationFinished(.failure(let error)):
                state.isWorking = false
                state.errorMessage = error.localizedDescription
                return .none

            case .downloadFinished(.success):
                state.isWorking = false
                return .none

            case .downloadFinished(.failure(let error)):
                state.isWorking = false
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isLoading = false
                state.isWorking = false
                return .cancel(id: CancelID.request)
            }
        }
    }

    private func operation(
        _ state: inout State,
        reload: Bool = true,
        work: @escaping @Sendable () async throws -> Void
    ) -> Effect<Action> {
        guard state.isConnected, !state.isWorking else { return .none }
        state.isWorking = true
        state.errorMessage = nil
        return .run { send in
            do {
                try await work()
                if reload {
                    await send(.operationFinished(.success(())))
                } else {
                    await send(.downloadFinished(.success(())))
                }
            } catch {
                await send(reload
                    ? .operationFinished(.failure(error))
                    : .downloadFinished(.failure(error)))
            }
        }
        .cancellable(id: CancelID.request, cancelInFlight: true)
    }

    private func fail(_ state: inout State, _ message: String) -> Effect<Action> {
        state.errorMessage = message
        return .none
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }
}
