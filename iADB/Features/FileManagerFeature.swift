import Foundation
import ComposableArchitecture

@Reducer
struct FileManagerFeature {
    @ObservableState
    struct State: Equatable {
        var currentPath = "/sdcard"
        var entries: [FileEntry] = []
        var pathHistory: [String] = ["/sdcard"]
        var isLoading = false
        var errorMessage: String?
        var selectedFile: FileEntry?
        var pulledFileData: Data?
        var showingFileContent = false
    }

    enum Action {
        case loadDirectory(path: String?)
        case directoryLoaded(Result<[FileEntry], Error>, path: String)
        case navigateTo(FileEntry)
        case navigateUp
        case navigateToPath(String)
        case goBack
        case pullFile(FileEntry)
        case filePulled(Result<Data, Error>)
        case deleteFile(FileEntry)
        case createDirectory(name: String)
        case pushFileData(data: Data, fileName: String)
        case operationCompleted(Result<Void, Error>)
    }

    private enum CancelID { case loadDirectory, fileOperation }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadDirectory(let path):
                let targetPath = path ?? state.currentPath
                state.isLoading = true
                state.errorMessage = nil

                return .run { send in
                    let output = try await adbClient.listDirectory(targetPath)
                    let lines = output.components(separatedBy: "\n")
                    let entries = lines.compactMap { FileEntry.parse(line: $0, parentPath: targetPath) }
                        .sorted { lhs, rhs in
                            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                        }
                    await send(.directoryLoaded(.success(entries), path: targetPath))
                } catch: { error, send in
                    await send(.directoryLoaded(.failure(error), path: targetPath))
                }

            case .directoryLoaded(.success(let entries), let path):
                state.isLoading = false
                state.entries = entries
                state.currentPath = path
                return .none

            case .directoryLoaded(.failure(let error), _):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .navigateTo(let entry):
                guard entry.isDirectory else {
                    state.selectedFile = entry
                    return .none
                }
                state.pathHistory.append(entry.fullPath)
                return .send(.loadDirectory(path: entry.fullPath))

            case .navigateUp:
                guard state.pathHistory.count > 1 else { return .none }
                state.pathHistory.removeLast()
                let parent = state.pathHistory.last ?? "/sdcard"
                return .send(.loadDirectory(path: parent))

            case .navigateToPath(let path):
                state.pathHistory.append(path)
                return .send(.loadDirectory(path: path))

            case .goBack:
                guard state.pathHistory.count > 1 else { return .none }
                state.pathHistory.removeLast()
                let prev = state.pathHistory.last ?? "/sdcard"
                return .send(.loadDirectory(path: prev))

            case .pullFile(let entry):
                state.isLoading = true
                return .run { send in
                    let data = try await adbClient.pullFile(entry.fullPath)
                    await send(.filePulled(.success(data)))
                } catch: { error, send in
                    await send(.filePulled(.failure(error)))
                }

            case .filePulled(.success(let data)):
                state.isLoading = false
                state.pulledFileData = data
                state.showingFileContent = true
                return .none

            case .filePulled(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .deleteFile(let entry):
                let flag = entry.isDirectory ? "-rf" : ""
                let path = entry.fullPath
                return .run { send in
                    _ = try await adbClient.shell("rm \(flag) \"\(path)\"")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .createDirectory(let name):
                let currentPath = state.currentPath
                return .run { send in
                    _ = try await adbClient.shell("mkdir -p \"\(currentPath)/\(name)\"")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .pushFileData(let data, let fileName):
                state.isLoading = true
                let currentPath = state.currentPath
                let remotePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"

                return .run { send in
                    try await adbClient.pushData(data, remotePath, 0o644)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .operationCompleted(.success):
                state.isLoading = false
                return .none

            case .operationCompleted(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}
