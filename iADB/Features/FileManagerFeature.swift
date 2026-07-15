import Foundation
import ComposableArchitecture

private actor TransferProgressGate {
    private var lastEmission: UInt64 = 0
    private let interval: UInt64 = 125_000_000

    func shouldEmit(_ progress: TransferProgress, force: Bool = false) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || lastEmission == 0 || now - lastEmission >= interval else { return false }
        lastEmission = now
        return true
    }
}

@Reducer
struct FileManagerFeature {
    static let maximumPreviewBytes = 8 * 1024 * 1024

    enum FileLoadPurpose: Equatable {
        case preview
        case download
    }

    enum FileSort: String, CaseIterable, Equatable {
        case nameAscending
        case nameDescending
        case sizeAscending
        case sizeDescending
        case modifiedNewest
        case modifiedOldest
        case permissions
    }

    struct FileOperationForm: Equatable, Identifiable {
        enum Kind: Equatable {
            case newFolder
            case newTextFile
            case goToPath
            case rename(FileEntry)
            case move(FileEntry)
            case moveSelection([FileEntry])
        }

        let kind: Kind
        var input: String
        var validationMessage: String?

        var id: String {
            switch kind {
            case .newFolder: "new-folder"
            case .newTextFile: "new-text-file"
            case .goToPath: "go-to-path"
            case .rename(let entry): "rename-\(entry.fullPath)"
            case .move(let entry): "move-\(entry.fullPath)"
            case .moveSelection(let entries): "move-selection-\(entries.map(\.fullPath).sorted().joined(separator: "|"))"
            }
        }
    }

    enum UploadConflictPolicy: String, CaseIterable, Equatable {
        case replace
        case keepBoth
        case cancel
    }

    struct UploadReview: Equatable, Identifiable {
        let id: UUID
        let localURL: URL
        let originalFileName: String
        var destinationFileName: String
        let totalBytes: Int64?
        let target: RemoteDeviceTarget
        let hasConflict: Bool
        var conflictPolicy: UploadConflictPolicy
    }

    struct MutationState: Equatable {
        enum Kind: Equatable {
            case create
            case delete
            case duplicate
            case move
        }

        let kind: Kind
        let objectName: String
    }

    struct BulkOperationState: Equatable {
        enum Kind: Equatable {
            case delete
            case duplicate
            case move(destinationDirectory: String)
            case download
        }

        struct Item: Equatable, Identifiable {
            enum Phase: Equatable {
                case pending
                case running
                case succeeded
                case failed(String)
            }

            let entry: FileEntry
            var phase: Phase = .pending

            var id: String { entry.fullPath }
        }

        let kind: Kind
        var items: [Item]

        var succeededCount: Int {
            items.count { $0.phase == .succeeded }
        }

        var failedCount: Int {
            items.count {
                if case .failed = $0.phase { return true }
                return false
            }
        }
    }

    @ObservableState
    struct State: Equatable {
        var remoteTarget = RemoteDeviceTarget.unavailable
        var currentPath = "/sdcard"
        var entries: [FileEntry] = []
        var pathHistory: [String] = ["/sdcard"]
        var isSelectionMode = false
        var selectedEntryPaths: Set<String> = []
        var sort = FileSort.nameAscending
        var searchQuery = ""
        var favorites = ["/sdcard"]
        /// Directory/content loading only. The previous snapshot remains visible during refresh.
        var isDirectoryLoading = false
        var isDetailLoading = false
        var activeMutation: MutationState?
        var bulkOperation: BulkOperationState?
        var operationSummary: String?
        var presentedForm: FileOperationForm?
        var uploadReview: UploadReview?
        var directoryLoadGeneration = 0
        var activeDirectoryLoadGeneration: Int?
        var errorMessage: String?
        var selectedFile: FileEntry?
        var showingFileActions = false
        var previewFileData: Data?
        var previewFilePath: String?
        var showingFilePreview = false
        var downloadedFileURL: URL?
        var downloadedFileURLs: [URL] = []
        var fileLoadPurpose: FileLoadPurpose?
        var detailLoadGeneration = 0
        var activeDetailLoadGeneration: Int?
        var activeBackgroundOperationID: UUID?
        var activeTransferRemotePath: String?
        var activeDownloadDirectoryURL: URL?

        var visibleEntries: [FileEntry] {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return entries }
            return entries.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.fullPath.localizedCaseInsensitiveContains(query)
            }
        }
    }

    enum Action {
        case loadDirectory(path: String?)
        case directoryLoaded(generation: Int, Result<[FileEntry], Error>, path: String)
        case navigateTo(FileEntry)
        case selectFile(FileEntry?)
        case selectInspector(FileEntry?)
        case toggleSelectionMode
        case toggleEntrySelection(FileEntry)
        case clearSelection
        case selectAllVisible([String])
        case setSort(FileSort)
        case setSearchQuery(String)
        case presentForm(FileOperationForm.Kind)
        case formInputChanged(String)
        case dismissForm
        case submitForm
        case navigateUp
        case navigateToPath(String)
        case goBack
        case previewSelectedFile
        case downloadSelectedFile
        case fileLoaded(generation: Int, Result<Data, Error>)
        case fileDownloaded(id: UUID, Result<URL, Error>)
        case transferProgress(id: UUID, TransferProgress)
        case dismissPreview
        case clearDownloadedFile
        case clearDownloadedFiles
        case deleteFile(FileEntry, confirmation: DestructiveActionConfirmation?)
        case deleteSelectedFiles(confirmation: DestructiveActionConfirmation?)
        case duplicateSelectedFiles
        case moveSelectedFiles(destinationDirectory: String)
        case downloadSelectedFiles
        case bulkItemStarted(path: String)
        case bulkItemCompleted(path: String, Result<Void, EquatableError>)
        case bulkDownloadItemCompleted(path: String, Result<URL, EquatableError>)
        case bulkOperationCompleted
        case bulkDownloadCompleted(id: UUID)
        case renameFile(FileEntry, newName: String)
        case moveFile(FileEntry, destinationPath: String)
        case duplicateFile(FileEntry)
        case createDirectory(name: String)
        case createFile(name: String)
        case reviewUpload(url: URL, fileName: String)
        case setUploadConflictPolicy(UploadConflictPolicy)
        case dismissUploadReview
        case confirmUpload
        case pushFileData(data: Data, fileName: String)
        case pushFile(url: URL, fileName: String)
        case pushFileResolved(url: URL, fileName: String, replaceExisting: Bool)
        case backgroundOperationCompleted(id: UUID, Result<Void, Error>)
        case transferCleanupCompleted(id: UUID, Result<Bool, EquatableError>)
        case retryDownload(remotePath: String)
        case cancelTransfer(id: UUID)
        case reportError(String)
        case cancelCurrentOperation
        case operationCompleted(Result<Void, Error>)
        case delegate(Delegate)

        enum Delegate: Equatable {
            case operationStarted(BackgroundOperation)
            case operationPhase(id: UUID, phase: BackgroundOperation.Phase, detail: String?)
            case operationFinished(id: UUID, outcome: BackgroundOperation.Outcome, date: Date)
            case cleanupCompleted(id: UUID, Result<Bool, EquatableError>)
            case operationProgress(id: UUID, completed: Int64, total: Int64?)
        }
    }

    private enum CancelID { case loadDirectory, detail, mutation, transfer }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadDirectory(let path):
                let targetPath = path ?? state.currentPath
                state.isDirectoryLoading = true
                state.directoryLoadGeneration += 1
                let generation = state.directoryLoadGeneration
                state.activeDirectoryLoadGeneration = generation
                state.errorMessage = nil
                PerformanceSignposts.directoryLoad("start")

                return .run { send in
                    let entries = try await adbClient.listDirectoryEntries(targetPath)
                    await send(.directoryLoaded(generation: generation, .success(entries), path: targetPath))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.directoryLoaded(generation: generation, .failure(error), path: targetPath))
                }
                .cancellable(id: CancelID.loadDirectory, cancelInFlight: true)

            case .directoryLoaded(let generation, .success(let entries), let path):
                guard state.activeDirectoryLoadGeneration == generation else { return .none }
                state.isDirectoryLoading = false
                state.activeDirectoryLoadGeneration = nil
                state.entries = Self.sorted(entries, by: state.sort)
                state.currentPath = path
                state.selectedEntryPaths = state.selectedEntryPaths.intersection(Set(entries.map(\.fullPath)))
                PerformanceSignposts.directoryLoad("success", entryCount: entries.count)
                return .none

            case .directoryLoaded(let generation, .failure(let error), let path):
                guard state.activeDirectoryLoadGeneration == generation else { return .none }
                state.isDirectoryLoading = false
                state.activeDirectoryLoadGeneration = nil
                state.errorMessage = error.localizedDescription
                PerformanceSignposts.directoryLoad("failed")
                if state.pathHistory.last == path, path != state.currentPath, state.pathHistory.count > 1 {
                    state.pathHistory.removeLast()
                }
                return .none

            case .navigateTo(let entry):
                guard !state.isSelectionMode else {
                    return .send(.toggleEntrySelection(entry))
                }
                guard entry.isNavigableDirectory else {
                    let changed = state.selectedFile?.fullPath != entry.fullPath
                    if changed { invalidateDetailSelection(in: &state) }
                    state.selectedFile = entry
                    state.showingFileActions = true
                    return changed ? .cancel(id: CancelID.detail) : .none
                }
                state.pathHistory.append(entry.fullPath)
                return .send(.loadDirectory(path: entry.fullPath))

            case .selectFile(let entry):
                let changed = state.selectedFile?.fullPath != entry?.fullPath
                if changed { invalidateDetailSelection(in: &state) }
                state.selectedFile = entry
                state.showingFileActions = entry != nil
                if entry == nil {
                    state.fileLoadPurpose = nil
                }
                return changed ? .cancel(id: CancelID.detail) : .none

            case .selectInspector(let entry):
                let changed = state.selectedFile?.fullPath != entry?.fullPath
                if changed { invalidateDetailSelection(in: &state) }
                state.selectedFile = entry
                state.showingFileActions = false
                if entry == nil {
                    state.fileLoadPurpose = nil
                }
                return changed ? .cancel(id: CancelID.detail) : .none

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

            case .selectAllVisible(let paths):
                state.isSelectionMode = true
                state.selectedEntryPaths.formUnion(paths)
                return .none

            case .setSort(let sort):
                state.sort = sort
                state.entries = Self.sorted(state.entries, by: sort)
                return .none

            case .setSearchQuery(let query):
                state.searchQuery = query
                return .none

            case .presentForm(let kind):
                let input: String
                switch kind {
                case .newFolder, .newTextFile:
                    input = ""
                case .goToPath:
                    input = state.currentPath
                case .rename(let entry):
                    input = entry.name
                case .move(let entry):
                    input = entry.fullPath
                case .moveSelection:
                    input = state.currentPath
                }
                state.showingFileActions = false
                state.presentedForm = FileOperationForm(
                    kind: kind,
                    input: input,
                    validationMessage: Self.formValidationMessage(kind: kind, input: input)
                )
                return .none

            case .formInputChanged(let input):
                guard var form = state.presentedForm else { return .none }
                form.input = input
                form.validationMessage = Self.formValidationMessage(kind: form.kind, input: input)
                state.presentedForm = form
                return .none

            case .dismissForm:
                state.presentedForm = nil
                return .none

            case .submitForm:
                guard var form = state.presentedForm else { return .none }
                if let validationMessage = Self.formValidationMessage(kind: form.kind, input: form.input) {
                    form.validationMessage = validationMessage
                    state.presentedForm = form
                    return .none
                }
                state.presentedForm = nil
                switch form.kind {
                case .newFolder:
                    return .send(.createDirectory(name: form.input))
                case .newTextFile:
                    return .send(.createFile(name: form.input))
                case .goToPath:
                    return .send(.navigateToPath(form.input))
                case .rename(let entry):
                    return .send(.renameFile(entry, newName: form.input))
                case .move(let entry):
                    return .send(.moveFile(entry, destinationPath: form.input))
                case .moveSelection:
                    return .send(.moveSelectedFiles(destinationDirectory: form.input))
                }

            case .navigateUp:
                guard state.currentPath != "/" else { return .none }
                let deleted = (state.currentPath as NSString).deletingLastPathComponent
                let parent = deleted.isEmpty ? "/" : deleted
                state.pathHistory.append(parent)
                return .send(.loadDirectory(path: parent))

            case .navigateToPath(let path):
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
                    state.errorMessage = String(localized: "Enter an absolute path beginning with '/'.")
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
                    state.errorMessage = String(localized: "This file is too large to preview safely. Use Download to save it without loading it into memory.")
                    return .none
                }
                state.isDetailLoading = true
                state.showingFileActions = false
                state.fileLoadPurpose = .preview
                state.detailLoadGeneration &+= 1
                let generation = state.detailLoadGeneration
                state.activeDetailLoadGeneration = generation
                state.errorMessage = nil
                return .run { send in
                    let data = try await adbClient.pullFile(entry.fullPath, Self.maximumPreviewBytes)
                    await send(.fileLoaded(generation: generation, .success(data)))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.fileLoaded(generation: generation, .failure(error)))
                }
                .cancellable(id: CancelID.detail, cancelInFlight: true)

            case .downloadSelectedFile:
                guard let entry = state.selectedFile,
                      state.activeBackgroundOperationID == nil else { return .none }
                let downloadID = uuid()
                state.showingFileActions = false
                state.fileLoadPurpose = .download
                state.errorMessage = nil
                let destinationDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("iADBDownloads", isDirectory: true)
                    .appendingPathComponent(downloadID.uuidString, isDirectory: true)
                let destinationURL = destinationDirectory.appendingPathComponent(entry.name)
                state.activeBackgroundOperationID = downloadID
                state.activeDownloadDirectoryURL = destinationDirectory
                let operation = transferOperation(
                    id: downloadID,
                    kind: .download,
                    objectName: entry.name,
                    target: state.remoteTarget,
                    totalUnits: Int64(entry.size),
                    retryPayload: .download(remotePath: entry.fullPath),
                    startedAt: date.now
                )
                let downloadEffect: Effect<Action> = .run { send in
                    let progressGate = TransferProgressGate()
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
                    try await adbClient.pullFileToWithProgress(entry.fullPath, destinationURL) { progress in
                        let reported = TransferProgress(
                            completedUnits: progress.completedUnits,
                            totalUnits: Int64(entry.size)
                        )
                        if await progressGate.shouldEmit(reported) {
                            await send(.transferProgress(id: downloadID, reported))
                        }
                    }
                    let finalUnits = Int64(entry.size) ?? 0
                    await send(.transferProgress(
                        id: downloadID,
                        TransferProgress(completedUnits: finalUnits, totalUnits: finalUnits)
                    ))
                    await send(.fileDownloaded(id: downloadID, .success(destinationURL)))
                } catch: { error, send in
                    try? FileManager.default.removeItem(at: destinationDirectory)
                    guard !(error is CancellationError) else { return }
                    await send(.fileDownloaded(id: downloadID, .failure(error)))
                }
                .cancellable(id: CancelID.transfer, cancelInFlight: false)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    downloadEffect
                )

            case .fileLoaded(let generation, .success(let data)):
                guard state.activeDetailLoadGeneration == generation,
                      let path = state.selectedFile?.fullPath else { return .none }
                state.isDetailLoading = false
                state.activeDetailLoadGeneration = nil
                switch state.fileLoadPurpose {
                case .preview:
                    state.previewFileData = data
                    state.previewFilePath = path
                    state.showingFilePreview = true
                case .download, nil:
                    break
                }
                return .none

            case .fileDownloaded(let id, .success(let url)):
                guard state.activeBackgroundOperationID == id else { return .none }
                state.downloadedFileURL = url
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: .success(summary: String(localized: "Downloaded \(url.lastPathComponent)")),
                    date: date.now
                )))

            case .fileDownloaded(let id, .failure(let error)):
                guard state.activeBackgroundOperationID == id else { return .none }
                state.errorMessage = error.localizedDescription
                state.fileLoadPurpose = nil
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: .failure(message: error.localizedDescription, retryable: true),
                    date: date.now
                )))

            case .transferProgress(let id, let progress):
                guard state.activeBackgroundOperationID == id else { return .none }
                return .send(.delegate(.operationProgress(
                    id: id,
                    completed: progress.completedUnits,
                    total: progress.totalUnits
                )))

            case .fileLoaded(let generation, .failure(let error)):
                guard state.activeDetailLoadGeneration == generation else { return .none }
                state.isDetailLoading = false
                state.activeDetailLoadGeneration = nil
                state.errorMessage = error.localizedDescription
                state.fileLoadPurpose = nil
                return .none

            case .dismissPreview:
                state.showingFilePreview = false
                state.previewFileData = nil
                state.previewFilePath = nil
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

            case .clearDownloadedFiles:
                let directory = state.activeDownloadDirectoryURL
                state.downloadedFileURLs = []
                state.activeDownloadDirectoryURL = nil
                return .run { _ in
                    if let directory {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }

            case .deleteFile(let entry, let confirmation):
                guard state.activeMutation == nil else { return .none }
                guard let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: entry.fullPath) else {
                    state.errorMessage = String(localized: "The target device changed. Confirm Delete again on the connected device.")
                    return .none
                }
                state.showingFileActions = false
                state.activeMutation = MutationState(kind: .delete, objectName: entry.displayName)
                state.operationSummary = nil
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
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .deleteSelectedFiles(let confirmation):
                guard state.activeMutation == nil else { return .none }
                let selectedEntries = state.entries.filter { state.selectedEntryPaths.contains($0.fullPath) }
                guard !selectedEntries.isEmpty else { return .none }
                let objectID = Self.bulkOperationObjectID(paths: selectedEntries.map(\.fullPath))
                guard let confirmation,
                      state.remoteTarget.accepts(confirmation, objectID: objectID) else {
                    state.errorMessage = String(localized: "The target device changed. Confirm Delete again on the connected device.")
                    return .none
                }
                state.isSelectionMode = false
                state.activeMutation = MutationState(
                    kind: .delete,
                    objectName: "\(selectedEntries.count) selected items"
                )
                state.bulkOperation = BulkOperationState(
                    kind: .delete,
                    items: selectedEntries.map { BulkOperationState.Item(entry: $0) }
                )
                state.operationSummary = nil
                state.errorMessage = nil
                return .run { send in
                    for entry in selectedEntries {
                        try Task.checkCancellation()
                        await send(.bulkItemStarted(path: entry.fullPath))
                        do {
                            let flag = entry.isDirectory ? "-rf " : ""
                            _ = try await adbClient.shell("rm \(flag)\(adbShellQuote(entry.fullPath))")
                            await send(.bulkItemCompleted(path: entry.fullPath, .success(())))
                        } catch {
                            if error is CancellationError { throw error }
                            await send(.bulkItemCompleted(
                                path: entry.fullPath,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                    await send(.bulkOperationCompleted)
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .bulkItemStarted(let path):
                guard let index = state.bulkOperation?.items.firstIndex(where: { $0.id == path }) else {
                    return .none
                }
                state.bulkOperation?.items[index].phase = .running
                return .none

            case .bulkItemCompleted(let path, .success):
                guard let index = state.bulkOperation?.items.firstIndex(where: { $0.id == path }) else {
                    return .none
                }
                state.bulkOperation?.items[index].phase = .succeeded
                if state.bulkOperation?.kind != .download {
                    state.selectedEntryPaths.remove(path)
                }
                if state.bulkOperation?.kind != .duplicate,
                   state.bulkOperation?.kind != .download {
                    state.entries.removeAll { $0.fullPath == path }
                }
                return .none

            case .bulkItemCompleted(let path, .failure(let error)):
                guard let index = state.bulkOperation?.items.firstIndex(where: { $0.id == path }) else {
                    return .none
                }
                state.bulkOperation?.items[index].phase = .failed(error.message)
                return .none

            case .bulkOperationCompleted:
                guard let result = state.bulkOperation else { return .none }
                state.activeMutation = nil
                if result.kind != .download {
                    state.isSelectionMode = !state.selectedEntryPaths.isEmpty
                }
                state.operationSummary = String(
                    localized: "\(result.succeededCount) succeeded, \(result.failedCount) failed"
                )
                if result.failedCount > 0 {
                    state.errorMessage = state.operationSummary
                }
                return .none

            case .bulkDownloadItemCompleted(let path, .success(let url)):
                guard let index = state.bulkOperation?.items.firstIndex(where: { $0.id == path }) else {
                    return .none
                }
                state.bulkOperation?.items[index].phase = .succeeded
                state.downloadedFileURLs.append(url)
                return .none

            case .bulkDownloadItemCompleted(let path, .failure(let error)):
                guard let index = state.bulkOperation?.items.firstIndex(where: { $0.id == path }) else {
                    return .none
                }
                state.bulkOperation?.items[index].phase = .failed(error.message)
                return .none

            case .bulkDownloadCompleted(let id):
                guard state.activeBackgroundOperationID == id else { return .none }
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: state.downloadedFileURLs.isEmpty
                        ? .failure(message: state.operationSummary ?? String(localized: "Download failed"), retryable: false)
                        : .success(summary: state.operationSummary ?? String(localized: "Download completed")),
                    date: date.now
                )))

            case .duplicateSelectedFiles:
                guard state.activeMutation == nil else { return .none }
                let selectedEntries = state.entries.filter { state.selectedEntryPaths.contains($0.fullPath) }
                guard !selectedEntries.isEmpty else { return .none }
                let plans = selectedEntries.map { entry -> (FileEntry, String, String) in
                    let parentPath = (entry.fullPath as NSString).deletingLastPathComponent
                    let temporaryPath = Self.joinedPath(
                        parentPath.isEmpty ? "/" : parentPath,
                        ".iadb-copy-\(uuid().uuidString).tmp"
                    )
                    return (entry, temporaryPath, Self.duplicatedPath(for: entry))
                }
                state.isSelectionMode = false
                state.activeMutation = MutationState(
                    kind: .duplicate,
                    objectName: "\(selectedEntries.count) selected items"
                )
                state.bulkOperation = BulkOperationState(
                    kind: .duplicate,
                    items: selectedEntries.map { BulkOperationState.Item(entry: $0) }
                )
                state.operationSummary = nil
                state.errorMessage = nil
                return .run { send in
                    for (entry, temporaryPath, destinationPath) in plans {
                        try Task.checkCancellation()
                        await send(.bulkItemStarted(path: entry.fullPath))
                        do {
                            let source = adbShellQuote(entry.fullPath)
                            let temporary = adbShellQuote(temporaryPath)
                            let stageCommand = entry.isDirectory
                                ? "mkdir \(temporary) && cp -Rp \(source)/. \(temporary)/"
                                : entry.isSymlink
                                    ? "cp -P \(source) \(temporary)"
                                    : "cp -p \(source) \(temporary)"
                            _ = try await adbClient.shell(
                                stageCommand + "; "
                                    + Self.finalizeMoveCommand(from: temporaryPath, to: destinationPath)
                            )
                            await send(.bulkItemCompleted(path: entry.fullPath, .success(())))
                        } catch {
                            _ = try? await adbClient.shell("rm -rf \(adbShellQuote(temporaryPath))")
                            if error is CancellationError { throw error }
                            await send(.bulkItemCompleted(
                                path: entry.fullPath,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                    await send(.bulkOperationCompleted)
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .moveSelectedFiles(let destinationDirectory):
                guard state.activeMutation == nil else { return .none }
                let selectedEntries = state.entries.filter { state.selectedEntryPaths.contains($0.fullPath) }
                guard !selectedEntries.isEmpty,
                      destinationDirectory.hasPrefix("/"),
                      !destinationDirectory.contains("\0") else {
                    state.errorMessage = String(localized: "Choose a valid absolute destination directory.")
                    return .none
                }
                let plans = selectedEntries.map { entry in
                    (entry, Self.joinedPath(destinationDirectory, entry.name))
                }
                guard !plans.contains(where: { $0.0.fullPath == $0.1 }) else {
                    state.errorMessage = String(localized: "One or more items are already in that destination.")
                    return .none
                }
                state.isSelectionMode = false
                state.activeMutation = MutationState(
                    kind: .move,
                    objectName: "\(selectedEntries.count) selected items"
                )
                state.bulkOperation = BulkOperationState(
                    kind: .move(destinationDirectory: destinationDirectory),
                    items: selectedEntries.map { BulkOperationState.Item(entry: $0) }
                )
                state.operationSummary = nil
                state.errorMessage = nil
                return .run { send in
                    for (entry, destinationPath) in plans {
                        try Task.checkCancellation()
                        await send(.bulkItemStarted(path: entry.fullPath))
                        do {
                            _ = try await adbClient.shell(
                                Self.finalizeMoveCommand(from: entry.fullPath, to: destinationPath)
                            )
                            await send(.bulkItemCompleted(path: entry.fullPath, .success(())))
                        } catch {
                            if error is CancellationError { throw error }
                            await send(.bulkItemCompleted(
                                path: entry.fullPath,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                    await send(.bulkOperationCompleted)
                    await send(.loadDirectory(path: nil))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.operationCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .downloadSelectedFiles:
                guard state.activeBackgroundOperationID == nil else { return .none }
                let selectedEntries = state.entries.filter {
                    state.selectedEntryPaths.contains($0.fullPath) && !$0.isDirectory
                }
                guard !selectedEntries.isEmpty else {
                    state.errorMessage = String(localized: "Select one or more files to download. Folders are not included.")
                    return .none
                }
                let operationID = uuid()
                let destinationDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("iADBBulkDownloads", isDirectory: true)
                    .appendingPathComponent(operationID.uuidString, isDirectory: true)
                let totalUnits = selectedEntries.reduce(Int64(0)) {
                    $0 + (Int64($1.size) ?? 0)
                }
                state.activeBackgroundOperationID = operationID
                state.activeDownloadDirectoryURL = destinationDirectory
                state.downloadedFileURLs = []
                state.bulkOperation = BulkOperationState(
                    kind: .download,
                    items: selectedEntries.map { BulkOperationState.Item(entry: $0) }
                )
                state.operationSummary = nil
                state.errorMessage = nil
                let operation = transferOperation(
                    id: operationID,
                    kind: .download,
                    objectName: "\(selectedEntries.count) selected files",
                    target: state.remoteTarget,
                    totalUnits: totalUnits > 0 ? totalUnits : nil,
                    retryPayload: nil,
                    startedAt: date.now
                )
                let effect: Effect<Action> = .run { send in
                    try FileManager.default.createDirectory(
                        at: destinationDirectory,
                        withIntermediateDirectories: true
                    )
                    let progressGate = TransferProgressGate()
                    var completedBefore: Int64 = 0
                    for entry in selectedEntries {
                        try Task.checkCancellation()
                        await send(.bulkItemStarted(path: entry.fullPath))
                        let destinationURL = destinationDirectory.appendingPathComponent(entry.name)
                        let baseCompleted = completedBefore
                        do {
                            try await adbClient.pullFileToWithProgress(entry.fullPath, destinationURL) { progress in
                                let aggregate = TransferProgress(
                                    completedUnits: baseCompleted + progress.completedUnits,
                                    totalUnits: totalUnits > 0 ? totalUnits : nil
                                )
                                if await progressGate.shouldEmit(aggregate) {
                                    await send(.transferProgress(id: operationID, aggregate))
                                }
                            }
                            completedBefore += Int64(entry.size) ?? 0
                            await send(.bulkDownloadItemCompleted(
                                path: entry.fullPath,
                                .success(destinationURL)
                            ))
                        } catch {
                            if error is CancellationError { throw error }
                            await send(.bulkDownloadItemCompleted(
                                path: entry.fullPath,
                                .failure(EquatableError(error))
                            ))
                        }
                    }
                    if totalUnits > 0 {
                        await send(.transferProgress(
                            id: operationID,
                            TransferProgress(completedUnits: totalUnits, totalUnits: totalUnits)
                        ))
                    }
                    await send(.bulkOperationCompleted)
                    await send(.bulkDownloadCompleted(id: operationID))
                } catch: { error, send in
                    try? FileManager.default.removeItem(at: destinationDirectory)
                    guard !(error is CancellationError) else { return }
                    await send(.fileDownloaded(id: operationID, .failure(error)))
                }
                .cancellable(id: CancelID.transfer, cancelInFlight: false)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    effect
                )

            case .renameFile(let entry, let newName):
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = String(localized: "File name cannot be empty")
                    return .none
                }
                guard !newName.contains("/") else {
                    state.errorMessage = String(localized: "File name cannot contain '/'")
                    return .none
                }
                guard Self.isValidEntryName(newName) else {
                    state.errorMessage = String(localized: "File name contains unsupported characters")
                    return .none
                }
                let parentPath = (entry.fullPath as NSString).deletingLastPathComponent
                let destination = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
                state.showingFileActions = false
                return .send(.moveFile(entry, destinationPath: destination))

            case .moveFile(let entry, let destinationPath):
                guard state.activeMutation == nil else { return .none }
                let trimmed = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = String(localized: "Destination path cannot be empty")
                    return .none
                }
                guard destinationPath.hasPrefix("/"), !destinationPath.contains("\0") else {
                    state.errorMessage = String(localized: "Enter a valid absolute destination path")
                    return .none
                }
                guard destinationPath != entry.fullPath else {
                    state.errorMessage = String(localized: "Source and destination paths are the same")
                    return .none
                }
                state.showingFileActions = false
                state.activeMutation = MutationState(kind: .move, objectName: entry.displayName)
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
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .duplicateFile(let entry):
                guard state.activeMutation == nil else { return .none }
                state.showingFileActions = false
                state.activeMutation = MutationState(kind: .duplicate, objectName: entry.displayName)
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
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .createDirectory(let name):
                guard state.activeMutation == nil else { return .none }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = String(localized: "Folder name cannot be empty")
                    return .none
                }
                guard !name.contains("/") else {
                    state.errorMessage = String(localized: "Folder name cannot contain '/'")
                    return .none
                }
                guard Self.isValidEntryName(name) else {
                    state.errorMessage = String(localized: "Folder name contains unsupported characters")
                    return .none
                }
                state.activeMutation = MutationState(kind: .create, objectName: name)
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
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .createFile(let name):
                guard state.activeMutation == nil else { return .none }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.errorMessage = String(localized: "File name cannot be empty")
                    return .none
                }
                guard !name.contains("/") else {
                    state.errorMessage = String(localized: "File name cannot contain '/'")
                    return .none
                }
                guard Self.isValidEntryName(name) else {
                    state.errorMessage = String(localized: "File name contains unsupported characters")
                    return .none
                }
                state.activeMutation = MutationState(kind: .create, objectName: name)
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
                .cancellable(id: CancelID.mutation, cancelInFlight: true)

            case .reviewUpload(let url, let fileName):
                guard Self.isValidUploadName(fileName) else {
                    state.errorMessage = String(localized: "The selected file name is not supported on Android.")
                    return .none
                }
                let hasConflict = state.entries.contains {
                    $0.name.caseInsensitiveCompare(fileName) == .orderedSame
                }
                state.uploadReview = UploadReview(
                    id: uuid(),
                    localURL: url,
                    originalFileName: fileName,
                    destinationFileName: fileName,
                    totalBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                    target: state.remoteTarget,
                    hasConflict: hasConflict,
                    conflictPolicy: hasConflict ? .cancel : .keepBoth
                )
                return .none

            case .setUploadConflictPolicy(let policy):
                state.uploadReview?.conflictPolicy = policy
                return .none

            case .dismissUploadReview:
                state.uploadReview = nil
                return .none

            case .confirmUpload:
                guard var review = state.uploadReview else { return .none }
                guard state.remoteTarget.isConnected,
                      state.remoteTarget.deviceID == review.target.deviceID,
                      state.remoteTarget.transportGeneration == review.target.transportGeneration else {
                    state.uploadReview = nil
                    state.errorMessage = String(localized: "The target device changed. Review the upload again on the connected device.")
                    return .none
                }
                if review.hasConflict {
                    switch review.conflictPolicy {
                    case .cancel:
                        return .none
                    case .keepBoth:
                        review.destinationFileName = Self.availableUploadName(
                            for: review.originalFileName,
                            entries: state.entries
                        )
                    case .replace:
                        break
                    }
                }
                state.uploadReview = nil
                return .send(.pushFileResolved(
                    url: review.localURL,
                    fileName: review.destinationFileName,
                    replaceExisting: review.hasConflict && review.conflictPolicy == .replace
                ))

            case .pushFileData(let data, let fileName):
                guard Self.isValidUploadName(fileName) else {
                    state.errorMessage = String(localized: "The selected file name is not supported on Android.")
                    return .none
                }
                guard state.remoteTarget.isConnected else {
                    state.errorMessage = String(localized: "Reconnect to the target device before saving the file.")
                    return .none
                }
                guard state.activeBackgroundOperationID == nil else { return .none }
                state.errorMessage = nil
                let currentPath = state.currentPath
                let remotePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"
                let operationID = uuid()
                let temporaryPath = Self.joinedPath(currentPath, ".iadb-upload-\(operationID.uuidString).tmp")
                state.activeBackgroundOperationID = operationID
                state.activeTransferRemotePath = temporaryPath
                let operation = transferOperation(
                    id: operationID,
                    kind: .upload,
                    objectName: fileName,
                    target: state.remoteTarget,
                    totalUnits: Int64(data.count),
                    retryPayload: nil,
                    startedAt: date.now
                )
                let uploadEffect: Effect<Action> = .run { send in
                    try await adbClient.pushData(data, temporaryPath, 0o644)
                    _ = try await adbClient.shell(
                        Self.finalizeUploadCommand(from: temporaryPath, to: remotePath)
                    )
                    await send(.backgroundOperationCompleted(id: operationID, .success(())))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.backgroundOperationCompleted(id: operationID, .failure(error)))
                }
                .cancellable(id: CancelID.transfer, cancelInFlight: false)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    uploadEffect
                )

            case .pushFile(let url, let fileName):
                return .send(.pushFileResolved(
                    url: url,
                    fileName: fileName,
                    replaceExisting: false
                ))

            case .pushFileResolved(let url, let fileName, let replaceExisting):
                guard Self.isValidUploadName(fileName) else {
                    state.errorMessage = String(localized: "The selected file name is not supported on Android.")
                    return .none
                }
                guard state.remoteTarget.isConnected else {
                    state.errorMessage = String(localized: "Reconnect to the target device and review the upload again.")
                    return .none
                }
                guard state.activeBackgroundOperationID == nil else { return .none }
                state.errorMessage = nil
                let currentPath = state.currentPath
                let remotePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"
                let operationID = uuid()
                let temporaryPath = Self.joinedPath(currentPath, ".iadb-upload-\(operationID.uuidString).tmp")
                state.activeBackgroundOperationID = operationID
                state.activeTransferRemotePath = temporaryPath
                let totalUnits = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                let operation = transferOperation(
                    id: operationID,
                    kind: .upload,
                    objectName: fileName,
                    target: state.remoteTarget,
                    totalUnits: totalUnits,
                    retryPayload: nil,
                    startedAt: date.now
                )
                let uploadEffect: Effect<Action> = .run { send in
                    let progressGate = TransferProgressGate()
                    let isSecurityScoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                    }
                    try await adbClient.pushFileWithProgress(url, temporaryPath, 0o644) { progress in
                        if await progressGate.shouldEmit(progress) {
                            await send(.transferProgress(id: operationID, progress))
                        }
                    }
                    if let totalUnits {
                        await send(.transferProgress(
                            id: operationID,
                            TransferProgress(completedUnits: totalUnits, totalUnits: totalUnits)
                        ))
                    }
                    _ = try await adbClient.shell(
                        replaceExisting
                            ? Self.finalizeReplaceCommand(from: temporaryPath, to: remotePath)
                            : Self.finalizeUploadCommand(from: temporaryPath, to: remotePath)
                    )
                    await send(.backgroundOperationCompleted(id: operationID, .success(())))
                } catch: { error, send in
                    _ = try? await adbClient.shell("rm -f \(adbShellQuote(temporaryPath))")
                    guard !(error is CancellationError) else { return }
                    await send(.backgroundOperationCompleted(id: operationID, .failure(error)))
                }
                .cancellable(id: CancelID.transfer, cancelInFlight: false)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    uploadEffect
                )

            case .backgroundOperationCompleted(let id, .success):
                guard state.activeBackgroundOperationID == id else { return .none }
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                return .concatenate(
                    .send(.delegate(.operationFinished(
                        id: id,
                        outcome: .success(summary: String(localized: "Transfer completed")),
                        date: date.now
                    ))),
                    .send(.loadDirectory(path: nil))
                )

            case .backgroundOperationCompleted(let id, .failure(let error)):
                guard state.activeBackgroundOperationID == id else { return .none }
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                state.errorMessage = error.localizedDescription
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: .failure(message: error.localizedDescription, retryable: false),
                    date: date.now
                )))

            case .transferCleanupCompleted(let id, let result):
                return .send(.delegate(.cleanupCompleted(id: id, result)))

            case .retryDownload(let remotePath):
                guard state.remoteTarget.isConnected else {
                    state.errorMessage = String(localized: "Reconnect to the target device before retrying the download.")
                    return .none
                }
                guard let entry = ([state.selectedFile].compactMap { $0 } + state.entries)
                    .first(where: { $0.fullPath == remotePath }) else {
                    state.errorMessage = String(localized: "The remote file is no longer available in the current directory.")
                    return .none
                }
                state.selectedFile = entry
                return .send(.downloadSelectedFile)

            case .cancelTransfer(let id):
                guard state.activeBackgroundOperationID == id else { return .none }
                let partialRemotePath = state.activeTransferRemotePath
                let partialDownloadDirectory = state.activeDownloadDirectoryURL
                state.fileLoadPurpose = nil
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                state.downloadedFileURLs = []
                return .merge(
                    .cancel(id: CancelID.transfer),
                    cleanupTransferEffect(
                        operationID: id,
                        partialRemotePath: partialRemotePath,
                        partialDownloadDirectory: partialDownloadDirectory
                    )
                )

            case .reportError(let message):
                state.errorMessage = message
                return .none

            case .cancelCurrentOperation:
                let operationID = state.activeBackgroundOperationID
                let partialRemotePath = state.activeTransferRemotePath
                let partialDownloadDirectory = state.activeDownloadDirectoryURL
                let hadActiveDetailLoad = state.isDetailLoading
                    || state.activeDetailLoadGeneration != nil
                state.isDirectoryLoading = false
                state.activeDirectoryLoadGeneration = nil
                state.isDetailLoading = false
                state.activeDetailLoadGeneration = nil
                if hadActiveDetailLoad {
                    state.detailLoadGeneration &+= 1
                }
                state.activeMutation = nil
                state.bulkOperation = nil
                state.fileLoadPurpose = nil
                state.activeBackgroundOperationID = nil
                state.activeTransferRemotePath = nil
                state.activeDownloadDirectoryURL = nil
                state.downloadedFileURLs = []
                return .merge(
                    .cancel(id: CancelID.loadDirectory),
                    .cancel(id: CancelID.detail),
                    .cancel(id: CancelID.mutation),
                    .cancel(id: CancelID.transfer),
                    cleanupTransferEffect(
                        operationID: operationID,
                        partialRemotePath: partialRemotePath,
                        partialDownloadDirectory: partialDownloadDirectory
                    )
                )

            case .operationCompleted(.success):
                state.activeMutation = nil
                state.activeTransferRemotePath = nil
                return .none

            case .operationCompleted(.failure(let error)):
                state.activeMutation = nil
                state.errorMessage = error.localizedDescription
                state.activeTransferRemotePath = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func invalidateDetailSelection(in state: inout State) {
        let hadDetailState = state.isDetailLoading
            || state.activeDetailLoadGeneration != nil
            || state.previewFileData != nil
            || state.previewFilePath != nil
            || state.showingFilePreview
            || state.fileLoadPurpose == .preview

        state.isDetailLoading = false
        state.activeDetailLoadGeneration = nil
        if hadDetailState {
            state.detailLoadGeneration &+= 1
        }
        state.previewFileData = nil
        state.previewFilePath = nil
        state.showingFilePreview = false
        if state.fileLoadPurpose == .preview {
            state.fileLoadPurpose = nil
        }
    }

    private func transferOperation(
        id: UUID,
        kind: BackgroundOperation.Kind,
        objectName: String,
        target: RemoteDeviceTarget,
        totalUnits: Int64?,
        retryPayload: BackgroundOperation.RetryPayload?,
        startedAt: Date
    ) -> BackgroundOperation {
        BackgroundOperation(
            id: id,
            deviceID: target.deviceID,
            deviceName: target.deviceName,
            workspace: .files,
            kind: kind,
            objectName: objectName,
            phase: .running,
            completedUnits: nil,
            totalUnits: totalUnits,
            detail: kind == .upload
                ? String(localized: "Uploading to the target device…")
                : String(localized: "Downloading from the target device…"),
            isCancellable: true,
            isTransportDependent: true,
            cleanupState: .notRequired,
            outcome: nil,
            retryPayload: retryPayload,
            startedAt: startedAt,
            finishedAt: nil
        )
    }

    private func cleanupTransferEffect(
        operationID: UUID?,
        partialRemotePath: String?,
        partialDownloadDirectory: URL?
    ) -> Effect<Action> {
        .run { send in
            do {
                var didCleanUp = false
                if let partialRemotePath {
                    _ = try await adbClient.shell("rm -rf \(adbShellQuote(partialRemotePath))")
                    didCleanUp = true
                }
                if let partialDownloadDirectory {
                    if FileManager.default.fileExists(atPath: partialDownloadDirectory.path) {
                        try FileManager.default.removeItem(at: partialDownloadDirectory)
                        didCleanUp = true
                    }
                }
                if let operationID {
                    await send(.transferCleanupCompleted(id: operationID, .success(didCleanUp)))
                }
            } catch {
                if let operationID {
                    await send(.transferCleanupCompleted(
                        id: operationID,
                        .failure(EquatableError(error))
                    ))
                }
            }
        }
    }

    static func bulkOperationObjectID(paths: [String]) -> String {
        paths.sorted().joined(separator: "\u{0}")
    }

    static func sorted(_ entries: [FileEntry], by sort: FileSort) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sort {
            case .nameAscending:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .nameDescending:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            case .sizeAscending:
                return (Int64(lhs.size) ?? 0, lhs.name) < (Int64(rhs.size) ?? 0, rhs.name)
            case .sizeDescending:
                return (Int64(lhs.size) ?? 0, lhs.name) > (Int64(rhs.size) ?? 0, rhs.name)
            case .modifiedNewest:
                return ("\(lhs.date) \(lhs.time)", lhs.name) > ("\(rhs.date) \(rhs.time)", rhs.name)
            case .modifiedOldest:
                return ("\(lhs.date) \(lhs.time)", lhs.name) < ("\(rhs.date) \(rhs.time)", rhs.name)
            case .permissions:
                return (lhs.permissions, lhs.name) < (rhs.permissions, rhs.name)
            }
        }
    }

    private static func formValidationMessage(
        kind: FileOperationForm.Kind,
        input: String
    ) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .newFolder, .newTextFile, .rename:
            guard !trimmed.isEmpty else { return String(localized: "Name cannot be empty.") }
            guard !input.contains("/") else { return String(localized: "Name cannot contain '/'.") }
            guard isValidEntryName(input) else { return String(localized: "Name contains unsupported characters.") }
            if case .rename(let entry) = kind, input == entry.name {
                return String(localized: "Enter a different name.")
            }
        case .goToPath:
            guard !trimmed.isEmpty, input.hasPrefix("/"), !input.contains("\0") else {
                return String(localized: "Enter an absolute path beginning with '/'.")
            }
        case .move(let entry):
            guard !trimmed.isEmpty, input.hasPrefix("/"), !input.contains("\0") else {
                return String(localized: "Enter a valid absolute destination path.")
            }
            guard input != entry.fullPath else { return String(localized: "Source and destination paths are the same.") }
        case .moveSelection(let entries):
            guard !trimmed.isEmpty, input.hasPrefix("/"), !input.contains("\0") else {
                return String(localized: "Choose a valid absolute destination directory.")
            }
            let destinations = entries.map { joinedPath(input, $0.name) }
            guard !zip(entries, destinations).contains(where: { $0.0.fullPath == $0.1 }) else {
                return String(localized: "One or more items are already in that destination.")
            }
        }
        return nil
    }

    private static func availableUploadName(for fileName: String, entries: [FileEntry]) -> String {
        let names = Set(entries.map { $0.name.lowercased() })
        let path = fileName as NSString
        let ext = path.pathExtension
        let base = path.deletingPathExtension
        for index in 2...10_000 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !names.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")"
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

    private static func finalizeReplaceCommand(from sourcePath: String, to destinationPath: String) -> String {
        let source = adbShellQuote(sourcePath)
        let destination = adbShellQuote(destinationPath)
        return "rm -rf \(destination); mv \(source) \(destination)"
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
