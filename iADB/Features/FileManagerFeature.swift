import Foundation
import ComposableArchitecture

@Reducer
struct FileManagerFeature {
    enum FileLoadPurpose: Equatable {
        case preview
        case download
    }

    @ObservableState
    struct State: Equatable {
        var currentPath = "/sdcard"
        var entries: [FileEntry] = []
        var pathHistory: [String] = ["/sdcard"]
        var isSelectionMode = false
        var selectedEntryPaths: Set<String> = []
        var isLoading = false
        var errorMessage: String?
        var selectedFile: FileEntry?
        var showingFileActions = false
        var previewFileData: Data?
        var showingFilePreview = false
        var downloadedFileData: Data?
        var fileLoadPurpose: FileLoadPurpose?
    }

    enum Action {
        case loadDirectory(path: String?)
        case directoryLoaded(Result<[FileEntry], Error>, path: String)
        case navigateTo(FileEntry)
        case selectFile(FileEntry?)
        case toggleSelectionMode
        case toggleEntrySelection(FileEntry)
        case clearSelection
        case navigateUp
        case navigateToPath(String)
        case goBack
        case previewSelectedFile
        case downloadSelectedFile
        case fileLoaded(Result<Data, Error>)
        case dismissPreview
        case clearDownloadedFile
        case deleteFile(FileEntry)
        case deleteSelectedFiles
        case renameFile(FileEntry, newName: String)
        case moveFile(FileEntry, destinationPath: String)
        case duplicateFile(FileEntry)
        case createDirectory(name: String)
        case createFile(name: String)
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
                state.selectedEntryPaths = state.selectedEntryPaths.intersection(Set(entries.map(\.fullPath)))
                return .none

            case .directoryLoaded(.failure(let error), _):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .navigateTo(let entry):
                guard !state.isSelectionMode else {
                    return .send(.toggleEntrySelection(entry))
                }
                guard entry.isDirectory else {
                    state.selectedFile = entry
                    state.showingFileActions = true
                    return .none
                }
                state.pathHistory.append(entry.fullPath)
                return .send(.loadDirectory(path: entry.fullPath))

            case .selectFile(let entry):
                state.selectedFile = entry
                state.showingFileActions = entry != nil
                if entry == nil {
                    state.fileLoadPurpose = nil
                }
                return .none

            case .toggleSelectionMode:
                state.isSelectionMode.toggle()
                if !state.isSelectionMode {
                    state.selectedEntryPaths.removeAll()
                }
                return .none

            case .toggleEntrySelection(let entry):
                if state.selectedEntryPaths.contains(entry.fullPath) {
                    state.selectedEntryPaths.remove(entry.fullPath)
                } else {
                    state.selectedEntryPaths.insert(entry.fullPath)
                }
                return .none

            case .clearSelection:
                state.selectedEntryPaths.removeAll()
                state.isSelectionMode = false
                return .none

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

            case .previewSelectedFile:
                guard let entry = state.selectedFile else { return .none }
                state.isLoading = true
                state.showingFileActions = false
                state.fileLoadPurpose = .preview
                state.errorMessage = nil
                return .run { send in
                    let data = try await adbClient.pullFile(entry.fullPath)
                    await send(.fileLoaded(.success(data)))
                } catch: { error, send in
                    await send(.fileLoaded(.failure(error)))
                }

            case .downloadSelectedFile:
                guard let entry = state.selectedFile else { return .none }
                state.isLoading = true
                state.showingFileActions = false
                state.fileLoadPurpose = .download
                state.errorMessage = nil
                return .run { send in
                    let data = try await adbClient.pullFile(entry.fullPath)
                    await send(.fileLoaded(.success(data)))
                } catch: { error, send in
                    await send(.fileLoaded(.failure(error)))
                }

            case .fileLoaded(.success(let data)):
                state.isLoading = false
                switch state.fileLoadPurpose {
                case .preview:
                    state.previewFileData = data
                    state.showingFilePreview = true
                case .download:
                    state.downloadedFileData = data
                case nil:
                    break
                }
                return .none

            case .fileLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                state.fileLoadPurpose = nil
                return .none

            case .dismissPreview:
                state.showingFilePreview = false
                state.previewFileData = nil
                state.fileLoadPurpose = nil
                return .none

            case .clearDownloadedFile:
                state.downloadedFileData = nil
                state.fileLoadPurpose = nil
                return .none

            case .deleteFile(let entry):
                state.showingFileActions = false
                let flag = entry.isDirectory ? "-rf" : ""
                let path = entry.fullPath
                return .run { send in
                    _ = try await adbClient.shell("rm \(flag) \"\(path)\"")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .deleteSelectedFiles:
                let selectedEntries = state.entries.filter { state.selectedEntryPaths.contains($0.fullPath) }
                guard !selectedEntries.isEmpty else { return .none }
                state.isSelectionMode = false
                state.selectedEntryPaths.removeAll()
                let command = selectedEntries.map { entry in
                    let flag = entry.isDirectory ? "-rf " : ""
                    return "rm \(flag)\"\(entry.fullPath)\""
                }.joined(separator: " && ")
                return .run { send in
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .renameFile(let entry, let newName):
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "File name cannot be empty"
                    return .none
                }
                guard !trimmed.contains("/") else {
                    state.errorMessage = "File name cannot contain '/'"
                    return .none
                }
                let parentPath = (entry.fullPath as NSString).deletingLastPathComponent
                let destination = parentPath.isEmpty ? trimmed : "\(parentPath)/\(trimmed)"
                state.showingFileActions = false
                return .send(.moveFile(entry, destinationPath: destination))

            case .moveFile(let entry, let destinationPath):
                let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "Destination path cannot be empty"
                    return .none
                }
                state.showingFileActions = false
                let sourcePath = entry.fullPath
                return .run { send in
                    _ = try await adbClient.shell("mv \"\(sourcePath)\" \"\(trimmed)\"")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .duplicateFile(let entry):
                state.showingFileActions = false
                let sourcePath = entry.fullPath
                let destinationPath = duplicatedPath(for: entry)
                let command = entry.isDirectory
                    ? "cp -R \"\(sourcePath)\" \"\(destinationPath)\""
                    : "cp \"\(sourcePath)\" \"\(destinationPath)\""
                return .run { send in
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .createDirectory(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "Folder name cannot be empty"
                    return .none
                }
                guard !trimmed.contains("/") else {
                    state.errorMessage = "Folder name cannot contain '/'"
                    return .none
                }
                guard !trimmed.contains("\0") else {
                    state.errorMessage = "Invalid folder name"
                    return .none
                }
                let currentPath = state.currentPath
                return .run { send in
                    _ = try await adbClient.shell("mkdir -p \"\(currentPath)/\(trimmed)\"")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    await send(.operationCompleted(.failure(error)))
                }

            case .createFile(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "File name cannot be empty"
                    return .none
                }
                guard !trimmed.contains("/") else {
                    state.errorMessage = "File name cannot contain '/'"
                    return .none
                }
                guard !trimmed.contains("\0") else {
                    state.errorMessage = "Invalid file name"
                    return .none
                }
                let currentPath = state.currentPath
                return .run { send in
                    _ = try await adbClient.shell("touch \"\(currentPath)/\(trimmed)\"")
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

    private func duplicatedPath(for entry: FileEntry) -> String {
        let path = entry.fullPath as NSString
        let parent = path.deletingLastPathComponent
        let baseName = path.deletingPathExtension.isEmpty ? entry.name : path.deletingPathExtension.components(separatedBy: "/").last ?? entry.name
        let ext = path.pathExtension
        let duplicateName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
        return parent.isEmpty ? duplicateName : "\(parent)/\(duplicateName)"
    }
}
