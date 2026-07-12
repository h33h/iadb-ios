import Foundation
import ComposableArchitecture

@Reducer
struct FileManagerFeature {
    static let maximumPreviewBytes = 8 * 1024 * 1024
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
        var downloadedFileURL: URL?
        var fileLoadPurpose: FileLoadPurpose?
        var activeTransferRemotePath: String?
        var activeDownloadDirectoryURL: URL?
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
        case fileDownloaded(Result<URL, Error>)
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
        case pushFile(url: URL, fileName: String)
        case reportError(String)
        case cancelCurrentOperation
        case operationCompleted(Result<Void, Error>)
    }

    private enum CancelID { case loadDirectory, fileOperation }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            if state.isLoading {
                switch action {
                case .directoryLoaded, .fileLoaded, .fileDownloaded,
                     .operationCompleted, .cancelCurrentOperation, .reportError:
                    break
                default:
                    return .none
                }
            }
            switch action {
            case .loadDirectory(let path):
                let targetPath = path ?? state.currentPath
                state.isLoading = true
                state.errorMessage = nil

                return .run { send in
                    let entries = try await adbClient.listDirectoryEntries(targetPath)
                        .sorted { lhs, rhs in
                            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                        }
                    await send(.directoryLoaded(.success(entries), path: targetPath))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.directoryLoaded(.failure(error), path: targetPath))
                }
                .cancellable(id: CancelID.loadDirectory, cancelInFlight: true)

            case .directoryLoaded(.success(let entries), let path):
                state.isLoading = false
                state.entries = entries
                state.currentPath = path
                state.selectedEntryPaths = state.selectedEntryPaths.intersection(Set(entries.map(\.fullPath)))
                return .none

            case .directoryLoaded(.failure(let error), let path):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                if state.pathHistory.last == path, path != state.currentPath, state.pathHistory.count > 1 {
                    state.pathHistory.removeLast()
                }
                return .none

            case .navigateTo(let entry):
                guard !state.isSelectionMode else {
                    return .send(.toggleEntrySelection(entry))
                }
                guard entry.isNavigableDirectory else {
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
                guard state.currentPath != "/" else { return .none }
                let deleted = (state.currentPath as NSString).deletingLastPathComponent
                let parent = deleted.isEmpty ? "/" : deleted
                state.pathHistory.append(parent)
                return .send(.loadDirectory(path: parent))

            case .navigateToPath(let path):
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
                    state.errorMessage = "Enter an absolute path beginning with '/'."
                    return .none
                }
                let normalized = NSString(string: path).standardizingPath
                if state.pathHistory.last != normalized {
                    state.pathHistory.append(normalized)
                }
                return .send(.loadDirectory(path: normalized))

            case .goBack:
                guard state.pathHistory.count > 1 else { return .none }
                state.pathHistory.removeLast()
                let prev = state.pathHistory.last ?? "/sdcard"
                return .send(.loadDirectory(path: prev))

            case .previewSelectedFile:
                guard let entry = state.selectedFile else { return .none }
                if let size = Int(entry.size), size > Self.maximumPreviewBytes {
                    state.showingFileActions = true
                    state.errorMessage = "This file is too large to preview safely. Use Download to save it without loading it into memory."
                    return .none
                }
                state.isLoading = true
                state.showingFileActions = false
                state.fileLoadPurpose = .preview
                state.errorMessage = nil
                return .run { send in
                    let data = try await adbClient.pullFile(entry.fullPath, Self.maximumPreviewBytes)
                    await send(.fileLoaded(.success(data)))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.fileLoaded(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .downloadSelectedFile:
                guard let entry = state.selectedFile else { return .none }
                state.isLoading = true
                state.showingFileActions = false
                state.fileLoadPurpose = .download
                state.errorMessage = nil
                let destinationDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("iADBDownloads", isDirectory: true)
                    .appendingPathComponent(uuid().uuidString, isDirectory: true)
                let destinationURL = destinationDirectory.appendingPathComponent(entry.name)
                state.activeDownloadDirectoryURL = destinationDirectory
                return .run { send in
                    let downloadsRoot = destinationDirectory.deletingLastPathComponent()
                    if let staleItems = try? FileManager.default.contentsOfDirectory(
                        at: downloadsRoot,
                        includingPropertiesForKeys: nil
                    ) {
                        for item in staleItems where item != destinationDirectory {
                            try? FileManager.default.removeItem(at: item)
                        }
                    }
                    try FileManager.default.createDirectory(
                        at: destinationDirectory,
                        withIntermediateDirectories: true
                    )
                    try await adbClient.pullFileTo(entry.fullPath, destinationURL)
                    await send(.fileDownloaded(.success(destinationURL)))
                } catch: { error, send in
                    try? FileManager.default.removeItem(at: destinationDirectory)
                    guard !(error is CancellationError) else { return }
                    await send(.fileDownloaded(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .fileLoaded(.success(let data)):
                state.isLoading = false
                switch state.fileLoadPurpose {
                case .preview:
                    state.previewFileData = data
                    state.showingFilePreview = true
                case .download, nil:
                    break
                }
                return .none

            case .fileDownloaded(.success(let url)):
                state.isLoading = false
                state.downloadedFileURL = url
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                return .none

            case .fileDownloaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                state.fileLoadPurpose = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
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
                state.selectedFile = nil
                return .none

            case .clearDownloadedFile:
                let url = state.downloadedFileURL
                state.downloadedFileURL = nil
                state.fileLoadPurpose = nil
                state.selectedFile = nil
                return .run { _ in
                    if let url {
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                }

            case .deleteFile(let entry):
                state.showingFileActions = false
                state.isLoading = true
                state.errorMessage = nil
                let flag = entry.isDirectory ? "-rf" : ""
                let path = entry.fullPath
                return .run { send in
                    let command = flag.isEmpty
                        ? "rm \(adbShellQuote(path))"
                        : "rm \(flag) \(adbShellQuote(path))"
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .deleteSelectedFiles:
                let selectedEntries = state.entries.filter { state.selectedEntryPaths.contains($0.fullPath) }
                guard !selectedEntries.isEmpty else { return .none }
                state.isSelectionMode = false
                state.selectedEntryPaths.removeAll()
                state.isLoading = true
                state.errorMessage = nil
                let command = selectedEntries.map { entry in
                    let flag = entry.isDirectory ? "-rf " : ""
                    return "rm \(flag)\(adbShellQuote(entry.fullPath))"
                }.joined(separator: " && ")
                return .run { send in
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .renameFile(let entry, let newName):
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "File name cannot be empty"
                    return .none
                }
                guard !newName.contains("/") else {
                    state.errorMessage = "File name cannot contain '/'"
                    return .none
                }
                guard Self.isValidEntryName(newName) else {
                    state.errorMessage = "File name contains unsupported characters"
                    return .none
                }
                let parentPath = (entry.fullPath as NSString).deletingLastPathComponent
                let destination = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
                state.showingFileActions = false
                return .send(.moveFile(entry, destinationPath: destination))

            case .moveFile(let entry, let destinationPath):
                let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "Destination path cannot be empty"
                    return .none
                }
                guard destinationPath.hasPrefix("/"), !destinationPath.contains("\0") else {
                    state.errorMessage = "Enter a valid absolute destination path"
                    return .none
                }
                guard destinationPath != entry.fullPath else {
                    state.errorMessage = "Source and destination paths are the same"
                    return .none
                }
                state.showingFileActions = false
                state.isLoading = true
                state.errorMessage = nil
                let sourcePath = entry.fullPath
                return .run { send in
                    let command = Self.finalizeMoveCommand(from: sourcePath, to: destinationPath)
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .duplicateFile(let entry):
                state.showingFileActions = false
                state.isLoading = true
                state.errorMessage = nil
                let sourcePath = entry.fullPath
                let destinationPath = Self.duplicatedPath(for: entry)
                let parentPath = (sourcePath as NSString).deletingLastPathComponent
                let temporaryPath = Self.joinedPath(
                    parentPath.isEmpty ? "/" : parentPath,
                    ".iadb-copy-\(uuid().uuidString).tmp"
                )
                state.activeTransferRemotePath = temporaryPath
                return .run { send in
                    let source = adbShellQuote(sourcePath)
                    let temporary = adbShellQuote(temporaryPath)
                    let stageCommand: String
                    if entry.isDirectory {
                        stageCommand = "mkdir \(temporary) && cp -Rp \(source)/. \(temporary)/"
                    } else if entry.isSymlink {
                        stageCommand = "cp -P \(source) \(temporary)"
                    } else {
                        stageCommand = "cp -p \(source) \(temporary)"
                    }
                    let command = stageCommand + " && "
                        + Self.finalizeMoveCommand(from: temporaryPath, to: destinationPath)
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -rf \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .createDirectory(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "Folder name cannot be empty"
                    return .none
                }
                guard !name.contains("/") else {
                    state.errorMessage = "Folder name cannot contain '/'"
                    return .none
                }
                guard Self.isValidEntryName(name) else {
                    state.errorMessage = "Folder name contains unsupported characters"
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                let currentPath = state.currentPath
                return .run { send in
                    let path = Self.joinedPath(currentPath, name)
                    _ = try await adbClient.shell("mkdir \(adbShellQuote(path))")
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .createFile(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = "File name cannot be empty"
                    return .none
                }
                guard !name.contains("/") else {
                    state.errorMessage = "File name cannot contain '/'"
                    return .none
                }
                guard Self.isValidEntryName(name) else {
                    state.errorMessage = "File name contains unsupported characters"
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                let currentPath = state.currentPath
                let temporaryPath = Self.joinedPath(currentPath, ".iadb-create-\(uuid().uuidString).tmp")
                state.activeTransferRemotePath = temporaryPath
                return .run { send in
                    let path = Self.joinedPath(currentPath, name)
                    let temporary = adbShellQuote(temporaryPath)
                    let command = "(set -C; : > \(temporary)) && "
                        + Self.finalizeMoveCommand(from: temporaryPath, to: path)
                    _ = try await adbClient.shell(command)
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .pushFileData(let data, let fileName):
                guard Self.isValidUploadName(fileName) else {
                    state.errorMessage = "The selected file name is not supported on Android."
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                let currentPath = state.currentPath
                let remotePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"
                let temporaryPath = Self.joinedPath(currentPath, ".iadb-upload-\(uuid().uuidString).tmp")
                state.activeTransferRemotePath = temporaryPath

                return .run { send in
                    try await adbClient.pushData(data, temporaryPath, 0o644)
                    _ = try await adbClient.shell(
                        Self.finalizeUploadCommand(from: temporaryPath, to: remotePath)
                    )
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .pushFile(let url, let fileName):
                guard Self.isValidUploadName(fileName) else {
                    state.errorMessage = "The selected file name is not supported on Android."
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                let currentPath = state.currentPath
                let remotePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"
                let temporaryPath = Self.joinedPath(currentPath, ".iadb-upload-\(uuid().uuidString).tmp")
                state.activeTransferRemotePath = temporaryPath

                return .run { send in
                    let isSecurityScoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                    }
                    try await adbClient.pushFile(url, temporaryPath, 0o644)
                    _ = try await adbClient.shell(
                        Self.finalizeUploadCommand(from: temporaryPath, to: remotePath)
                    )
                    await send(.operationCompleted(.success(())))
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.fileOperation, cancelInFlight: true)

            case .reportError(let message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .cancelCurrentOperation:
                let partialRemotePath = state.activeTransferRemotePath
                let partialDownloadDirectory = state.activeDownloadDirectoryURL
                state.isLoading = false
                state.fileLoadPurpose = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                return .merge(
                    .cancel(id: CancelID.loadDirectory),
                    .cancel(id: CancelID.fileOperation),
                    .run { _ in
                        if let partialRemotePath {
                            _ = try? await adbClient.shell("rm -rf \(adbShellQuote(partialRemotePath))")
                        }
                        if let partialDownloadDirectory {
                            try? FileManager.default.removeItem(at: partialDownloadDirectory)
                        }
                    }
                )

            case .operationCompleted(.success):
                state.isLoading = false
                state.activeTransferRemotePath = nil
                return .none

            case .operationCompleted(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                state.activeTransferRemotePath = nil
                return .none
            }
        }
    }

    private static func duplicatedPath(for entry: FileEntry) -> String {
        let path = entry.fullPath as NSString
        let parent = path.deletingLastPathComponent
        let baseName = path.deletingPathExtension.isEmpty ? entry.name : path.deletingPathExtension.components(separatedBy: "/").last ?? entry.name
        let ext = path.pathExtension
        let duplicateName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
        return parent.isEmpty ? duplicateName : "\(parent)/\(duplicateName)"
    }

    private static func joinedPath(_ parent: String, _ child: String) -> String {
        parent.hasSuffix("/") ? "\(parent)\(child)" : "\(parent)/\(child)"
    }

    private static func isValidEntryName(_ name: String) -> Bool {
        name != "."
            && name != ".."
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isValidUploadName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && isValidEntryName(name)
    }

    private static func noClobberGuard(for path: String) -> String {
        let message = adbShellQuote("Destination already exists: \(path)")
        let quotedPath = adbShellQuote(path)
        return "if [ -e \(quotedPath) ] || [ -L \(quotedPath) ]; then printf '%s\\n' \(message) >&2; exit 17; fi"
    }

    private static func finalizeUploadCommand(from temporaryPath: String, to destinationPath: String) -> String {
        finalizeMoveCommand(from: temporaryPath, to: destinationPath)
    }

    private static func finalizeMoveCommand(from sourcePath: String, to destinationPath: String) -> String {
        let source = adbShellQuote(sourcePath)
        let destination = adbShellQuote(destinationPath)
        let failure = adbShellQuote("Could not safely create destination: \(destinationPath)")
        return noClobberGuard(for: destinationPath)
            + "; mv -n \(source) \(destination)"
            + "; if [ -e \(source) ] || [ -L \(source) ]; then printf '%s\\n' \(failure) >&2; exit 18; fi"
    }

}
