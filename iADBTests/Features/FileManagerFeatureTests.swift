import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct FileManagerFeatureTests {
    @Test
    func rejectsRelativePathWithoutLeavingCurrentDirectory() async {
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.navigateToPath("sdcard/Download")) {
            $0.errorMessage = "Enter an absolute path beginning with '/'."
        }
        #expect(store.state.currentPath == "/sdcard")
        #expect(store.state.pathHistory == ["/sdcard"])
    }

    private static let lsOutput = """
    drwxr-xr-x  2 root root 4096 2024-01-01 00:00 Documents
    -rw-r--r--  1 root root 1234 2024-01-01 00:00 file.txt
    """

    @Test
    func loadDirectorySuccess() async {
        let lsOutput = Self.lsOutput
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in
                lsOutput.components(separatedBy: "\n").compactMap {
                    FileEntry.parse(line: $0, parentPath: "/sdcard")
                }
            }
        }
        store.exhaustivity = .off

        await store.send(.loadDirectory(path: "/sdcard")) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.currentPath = "/sdcard"
        }
    }

    @Test
    func loadDirectoryError() async {
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in throw ADBError.notConnected }
        }

        await store.send(.loadDirectory(path: "/sdcard")) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
    }

    @Test
    func navigateToDirectory() async {
        let dir = FileEntry(
            name: "Downloads",
            permissions: "drwxr-xr-x",
            owner: "root",
            group: "root",
            size: "4096",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: true,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/Downloads"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.navigateTo(dir)) {
            $0.pathHistory = ["/sdcard", "/sdcard/Downloads"]
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.currentPath = "/sdcard/Downloads"
            $0.entries = []
        }
    }

    @Test
    func navigateToFile() async {
        let file = FileEntry(
            name: "file.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "1234",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/file.txt"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.navigateTo(file)) {
            $0.selectedFile = file
            $0.showingFileActions = true
        }
    }

    @Test
    func selectionModeTogglesAndSelectsEntries() async {
        let file = FileEntry(
            name: "file.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "1234",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/file.txt"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.toggleSelectionMode) {
            $0.isSelectionMode = true
        }

        await store.send(.toggleEntrySelection(file)) {
            $0.selectedEntryPaths = ["/sdcard/file.txt"]
        }

        await store.send(.clearSelection) {
            $0.isSelectionMode = false
            $0.selectedEntryPaths = []
        }
    }

    @Test
    func previewSelectedFile() async {
        let file = FileEntry(
            name: "file.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "1234",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/file.txt"
        )
        let fileData = Data("hello".utf8)

        let store = TestStore(
            initialState: FileManagerFeature.State(selectedFile: file, showingFileActions: true)
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.pullFile = { _, _ in fileData }
        }

        await store.send(.previewSelectedFile) {
            $0.isDetailLoading = true
            $0.showingFileActions = false
            $0.fileLoadPurpose = .preview
            $0.detailLoadGeneration = 1
            $0.activeDetailLoadGeneration = 1
        }
        await store.receive(\.fileLoaded) {
            $0.isDetailLoading = false
            $0.activeDetailLoadGeneration = nil
            $0.previewFileData = fileData
            $0.previewFilePath = file.fullPath
            $0.showingFilePreview = true
        }
    }

    @Test
    func downloadSelectedFile() async {
        let file = FileEntry(
            name: "photo.jpg",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "5000",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/photo.jpg"
        )
        let downloadURL = LockIsolated<URL?>(nil)
        let downloadID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

        let store = TestStore(
            initialState: FileManagerFeature.State(selectedFile: file, showingFileActions: true)
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.pullFileToWithProgress = { _, url, _ in downloadURL.setValue(url) }
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.uuid = .constant(downloadID)
        }

        await store.send(.downloadSelectedFile) {
            $0.showingFileActions = false
            $0.fileLoadPurpose = .download
            $0.activeBackgroundOperationID = downloadID
            $0.activeDownloadDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iADBDownloads", isDirectory: true)
                .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        }
        await store.receive(\.delegate)
        await store.receive(\.transferProgress)
        await store.receive(\.delegate)

        await store.receive(\.fileDownloaded) {
            $0.downloadedFileURL = downloadURL.value
            $0.activeBackgroundOperationID = nil
            $0.activeDownloadDirectoryURL = nil
        }
        await store.receive(\.delegate)
    }

    @Test
    func navigateUp() async {
        let store = TestStore(
            initialState: FileManagerFeature.State(
                currentPath: "/sdcard/Downloads",
                pathHistory: ["/sdcard", "/sdcard/Downloads"]
            )
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.navigateUp) {
            $0.pathHistory = ["/sdcard", "/sdcard/Downloads", "/sdcard"]
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.currentPath = "/sdcard"
            $0.entries = []
        }
    }

    @Test
    func navigateUpUsesFilesystemParentRatherThanHistoryBack() async {
        let store = TestStore(initialState: FileManagerFeature.State(
            currentPath: "/data/local/tmp",
            pathHistory: ["/sdcard", "/data/local/tmp"]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.navigateUp) {
            $0.pathHistory = ["/sdcard", "/data/local/tmp", "/data/local"]
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
            $0.currentPath = "/data/local"
        }
    }

    @Test
    func goBack() async {
        let store = TestStore(
            initialState: FileManagerFeature.State(
                currentPath: "/sdcard/Downloads",
                pathHistory: ["/sdcard", "/sdcard/Downloads"]
            )
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.goBack) {
            $0.pathHistory = ["/sdcard"]
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.currentPath = "/sdcard"
            $0.entries = []
        }
    }

    @Test
    func goBackAtRoot() async {
        let store = TestStore(
            initialState: FileManagerFeature.State(pathHistory: ["/sdcard"])
        ) {
            FileManagerFeature()
        }

        await store.send(.goBack)
        // No effect — only one item in history
    }

    @Test
    func dismissPreview() async {
        let file = FileEntry(
            name: "photo.jpg",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "5000",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/photo.jpg"
        )

        let store = TestStore(initialState: FileManagerFeature.State(
            selectedFile: file,
            previewFileData: Data([0x01]),
            previewFilePath: file.fullPath,
            showingFilePreview: true,
            fileLoadPurpose: .preview
        )) {
            FileManagerFeature()
        }

        await store.send(.dismissPreview) {
            $0.previewFileData = nil
            $0.previewFilePath = nil
            $0.showingFilePreview = false
            $0.fileLoadPurpose = nil
            $0.selectedFile = nil
        }
    }

    @Test
    func changingInspectorSelectionRejectsLatePreviewBytes() async {
        let first = FileEntry(
            name: "first.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "shell",
            size: "5",
            date: "2026-07-13",
            time: "09:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/first.txt"
        )
        let second = FileEntry(
            name: "second.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "shell",
            size: "6",
            date: "2026-07-13",
            time: "09:01",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/second.txt"
        )
        let store = TestStore(initialState: FileManagerFeature.State(
            isDetailLoading: true,
            selectedFile: first,
            fileLoadPurpose: .preview,
            detailLoadGeneration: 1,
            activeDetailLoadGeneration: 1
        )) {
            FileManagerFeature()
        }

        await store.send(.selectInspector(second)) {
            $0.isDetailLoading = false
            $0.selectedFile = second
            $0.fileLoadPurpose = nil
            $0.detailLoadGeneration = 2
            $0.activeDetailLoadGeneration = nil
        }

        await store.send(.fileLoaded(generation: 1, .success(Data("stale".utf8))))
        #expect(store.state.selectedFile == second)
        #expect(store.state.previewFileData == nil)
        #expect(store.state.previewFilePath == nil)
        #expect(!store.state.showingFilePreview)
    }

    @Test
    func clearDownloadedFile() async {
        let store = TestStore(initialState: FileManagerFeature.State(
            downloadedFileURL: URL(fileURLWithPath: "/tmp/iADBDownloads/test-id/iadb-download-test"),
            fileLoadPurpose: .download
        )) {
            FileManagerFeature()
        }

        await store.send(.clearDownloadedFile) {
            $0.downloadedFileURL = nil
            $0.fileLoadPurpose = nil
        }
    }

    @Test
    func deleteFile() async {
        let shellCommand = LockIsolated<String?>(nil)
        let file = FileEntry(
            name: "old.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/old.txt"
        )

        let target = Self.connectedTarget()
        let store = TestStore(initialState: FileManagerFeature.State(remoteTarget: target)) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.deleteFile(
            file,
            confirmation: target.confirmation(for: file.fullPath)
        )) {
            $0.activeMutation = .init(kind: .delete, objectName: "old.txt")
            $0.errorMessage = nil
        }

        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("old.txt") == true)
    }

    @Test
    func deleteSelectedFiles() async {
        let shellCommands = LockIsolated<[String]>([])
        let file = FileEntry(
            name: "old.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/old.txt"
        )
        let dir = FileEntry(
            name: "Docs",
            permissions: "drwxr-xr-x",
            owner: "root",
            group: "root",
            size: "4096",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: true,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/Docs"
        )

        let target = Self.connectedTarget()
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: target,
            entries: [file, dir],
            isSelectionMode: true,
            selectedEntryPaths: [file.fullPath, dir.fullPath]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { command in
                shellCommands.withValue { $0.append(command) }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        let objectID = FileManagerFeature.bulkOperationObjectID(paths: [file.fullPath, dir.fullPath])
        await store.send(.deleteSelectedFiles(
            confirmation: target.confirmation(for: objectID)
        )) {
            $0.isSelectionMode = false
            $0.activeMutation = .init(kind: .delete, objectName: "2 selected items")
            $0.bulkOperation = .init(kind: .delete, items: [
                .init(entry: file),
                .init(entry: dir),
            ])
            $0.errorMessage = nil
        }

        await store.receive(\.bulkItemStarted) {
            $0.bulkOperation?.items[0].phase = .running
        }
        await store.receive(\.bulkItemCompleted) {
            $0.bulkOperation?.items[0].phase = .succeeded
            $0.selectedEntryPaths.remove(file.fullPath)
            $0.entries.removeAll { $0.fullPath == file.fullPath }
        }
        await store.receive(\.bulkItemStarted) {
            $0.bulkOperation?.items[1].phase = .running
        }
        await store.receive(\.bulkItemCompleted) {
            $0.bulkOperation?.items[1].phase = .succeeded
            $0.selectedEntryPaths.remove(dir.fullPath)
            $0.entries.removeAll { $0.fullPath == dir.fullPath }
        }
        await store.receive(\.bulkOperationCompleted) {
            $0.activeMutation = nil
            $0.operationSummary = "2 succeeded, 0 failed"
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommands.value == [
            "rm '/sdcard/old.txt'",
            "rm -rf '/sdcard/Docs'",
        ])
    }

    @Test
    func partialBulkDeleteTracksEachItemAndKeepsOnlyFailureSelected() async {
        let succeeded = FileEntry(
            name: "remove.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "sdcard_rw",
            size: "10",
            date: "2026-07-13",
            time: "03:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/remove.txt"
        )
        let failed = FileEntry(
            name: "protected.txt",
            permissions: "-r--r--r--",
            owner: "root",
            group: "root",
            size: "20",
            date: "2026-07-13",
            time: "03:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/protected.txt"
        )
        let commands = LockIsolated<[String]>([])
        let target = Self.connectedTarget()
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: target,
            entries: [succeeded, failed],
            isSelectionMode: true,
            selectedEntryPaths: [succeeded.fullPath, failed.fullPath]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { command in
                commands.withValue { $0.append(command) }
                if command.contains("protected.txt") {
                    throw ADBError.commandFailed("Permission denied")
                }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [failed] }
        }
        store.exhaustivity = .off

        let objectID = FileManagerFeature.bulkOperationObjectID(
            paths: [succeeded.fullPath, failed.fullPath]
        )
        await store.send(.deleteSelectedFiles(
            confirmation: target.confirmation(for: objectID)
        ))
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkOperationCompleted)
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)
        store.exhaustivity = .on

        #expect(commands.value == [
            "rm '/sdcard/remove.txt'",
            "rm '/sdcard/protected.txt'",
        ])
        #expect(store.state.selectedEntryPaths == [failed.fullPath])
        #expect(store.state.isSelectionMode)
        #expect(store.state.operationSummary == "1 succeeded, 1 failed")
        #expect(store.state.errorMessage == nil)
        #expect(store.state.bulkOperation?.items[0].phase == .succeeded)
        #expect(store.state.bulkOperation?.items[1].phase == .failed("Command failed: Permission denied"))
    }

    private static func connectedTarget() -> RemoteDeviceTarget {
        RemoteDeviceTarget(
            deviceID: "serial:test-device",
            deviceName: "Pixel Test",
            transportGeneration: 1,
            switchedAt: Date(timeIntervalSince1970: 1),
            isConnected: true
        )
    }

    @Test
    func staleDirectoryResultAndDeleteConfirmationAreRejected() async {
        let file = FileEntry(
            name: "keep.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "10",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/keep.txt"
        )
        var currentTarget = Self.connectedTarget()
        let staleConfirmation = currentTarget.confirmation(for: file.fullPath)
        currentTarget.transportGeneration = 2
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: currentTarget,
            entries: [file],
            isDirectoryLoading: true,
            directoryLoadGeneration: 2,
            activeDirectoryLoadGeneration: 2
        )) {
            FileManagerFeature()
        }

        await store.send(.directoryLoaded(
            generation: 1,
            .success([]),
            path: "/sdcard"
        ))
        #expect(store.state.entries == [file])

        // Finish the current load only to make the destructive entry point
        // reachable; the stale target token must still be rejected.
        await store.send(.directoryLoaded(
            generation: 2,
            .success([file]),
            path: "/sdcard"
        )) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
        }
        await store.send(.deleteFile(file, confirmation: staleConfirmation)) {
            $0.errorMessage = "The target device changed. Confirm Delete again on the connected device."
        }
    }

    @Test
    func renameFile() async {
        let shellCommand = LockIsolated<String?>(nil)
        let file = FileEntry(
            name: "old.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/old.txt"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.renameFile(file, newName: "new.txt"))
        await store.receive(\.moveFile) {
            $0.activeMutation = .init(kind: .move, objectName: "old.txt")
            $0.errorMessage = nil
        }
        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("mv -n '/sdcard/old.txt' '/sdcard/new.txt'") == true)
        #expect(shellCommand.value?.contains("[ -e '/sdcard/old.txt' ] || [ -L '/sdcard/old.txt' ]") == true)
        #expect(shellCommand.value?.contains("Destination already exists") == true)
    }

    @Test
    func renameFileValidation() async {
        let file = FileEntry(
            name: "old.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/old.txt"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.renameFile(file, newName: "   ")) {
            $0.errorMessage = "File name cannot be empty"
        }
    }

    @Test
    func moveFile() async {
        let shellCommand = LockIsolated<String?>(nil)
        let file = FileEntry(
            name: "old.txt",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/old.txt"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.moveFile(file, destinationPath: "/sdcard/Documents/old.txt")) {
            $0.activeMutation = .init(kind: .move, objectName: "old.txt")
            $0.errorMessage = nil
        }
        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("mv -n '/sdcard/old.txt' '/sdcard/Documents/old.txt'") == true)
    }

    @Test
    func duplicateFile() async {
        let shellCommand = LockIsolated<String?>(nil)
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let file = FileEntry(
            name: "photo.jpg",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "100",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/photo.jpg"
        )

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.uuid = .constant(copyID)
        }

        await store.send(.duplicateFile(file)) {
            $0.activeMutation = .init(kind: .duplicate, objectName: "photo.jpg")
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-copy-\(copyID.uuidString).tmp"
        }
        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("cp -p '/sdcard/photo.jpg' '/sdcard/.iadb-copy-\(copyID.uuidString).tmp'") == true)
        #expect(shellCommand.value?.contains("mv -n '/sdcard/.iadb-copy-\(copyID.uuidString).tmp' '/sdcard/photo copy.jpg'") == true)
    }

    @Test
    func createDirectory() async {
        let shellCommand = LockIsolated<String?>(nil)
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.createDirectory(name: "NewFolder")) {
            $0.activeMutation = .init(kind: .create, objectName: "NewFolder")
            $0.errorMessage = nil
        }

        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("NewFolder") == true)
    }

    @Test
    func createFile() async {
        let shellCommand = LockIsolated<String?>(nil)
        let createID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.uuid = .constant(createID)
        }

        await store.send(.createFile(name: "notes.txt")) {
            $0.activeMutation = .init(kind: .create, objectName: "notes.txt")
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-create-\(createID.uuidString).tmp"
        }

        await store.receive(\.operationCompleted) {
            $0.activeMutation = nil
            $0.activeTransferRemotePath = nil
        }

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("set -C; : > '/sdcard/.iadb-create-\(createID.uuidString).tmp'") == true)
        #expect(shellCommand.value?.contains("mv -n '/sdcard/.iadb-create-\(createID.uuidString).tmp' '/sdcard/notes.txt'") == true)
    }

    @Test
    func createFileValidation() async {
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.createFile(name: "   ")) {
            $0.errorMessage = "File name cannot be empty"
        }
    }

    @Test
    func pathsAndNamesPreserveLeadingAndTrailingSpaces() async {
        let entry = FileEntry(
            name: " report ",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "10",
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/ report "
        )
        let commands = LockIsolated<[String]>([])
        let createID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { command in
                commands.withValue { $0.append(command) }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.uuid = .constant(createID)
        }
        store.exhaustivity = .off

        await store.send(.renameFile(entry, newName: " renamed "))
        await store.receive(\.moveFile)
        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)

        await store.send(.createFile(name: " notes "))
        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)
        store.exhaustivity = .on

        #expect(commands.value.contains { $0.contains("'/sdcard/ report '") && $0.contains("'/sdcard/ renamed '") })
        #expect(commands.value.contains { $0.contains("'/sdcard/ notes '") })
    }

    @Test
    func navigateToPathPreservesWhitespace() async {
        let requestedPath = LockIsolated<String?>(nil)
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { path in
                requestedPath.setValue(path)
                return []
            }
        }
        store.exhaustivity = .off
        await store.send(.navigateToPath("/sdcard/ reports "))
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)
        store.exhaustivity = .on

        #expect(requestedPath.value == "/sdcard/ reports ")
    }

    @Test
    func oversizedFileUsesStreamingDownloadRecoveryInsteadOfPreview() async {
        let entry = FileEntry(
            name: "large.log",
            permissions: "-rw-r--r--",
            owner: "root",
            group: "root",
            size: String(FileManagerFeature.maximumPreviewBytes + 1),
            date: "2024-01-01",
            time: "00:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/large.log"
        )
        let store = TestStore(
            initialState: FileManagerFeature.State(selectedFile: entry, showingFileActions: true)
        ) {
            FileManagerFeature()
        }

        await store.send(.previewSelectedFile) {
            $0.errorMessage = "This file is too large to preview safely. Use Download to save it without loading it into memory."
        }
        #expect(store.state.isDirectoryLoading == false)
        #expect(store.state.showingFileActions)
    }

    @Test
    func pushFileData() async {
        let pushedPath = LockIsolated<String?>(nil)
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: Self.connectedTarget()
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.pushData = { _, path, _ in pushedPath.setValue(path) }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFileData(data: Data([1, 2, 3]), fileName: "upload.bin")) {
            $0.errorMessage = nil
            $0.activeBackgroundOperationID = uploadID
            $0.activeTransferRemotePath = "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp"
        }
        await store.receive(\.delegate)

        await store.receive(\.backgroundOperationCompleted) {
            $0.activeBackgroundOperationID = nil
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.delegate)

        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(pushedPath.value == "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp")
    }

    @Test
    func rejectsImportedFileNameThatWouldBreakDirectoryListing() async {
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        }

        await store.send(.pushFile(
            url: URL(fileURLWithPath: "/tmp/bad-name.bin"),
            fileName: "bad\nname.bin"
        ))
        await store.receive(\.pushFileResolved) {
            $0.errorMessage = "The selected file name is not supported on Android."
        }
    }

    @Test
    func streamsImportedFileWithoutLoadingItIntoMemory() async {
        let localURL = URL(fileURLWithPath: "/tmp/large-upload.bin")
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let pushedPath = LockIsolated<String?>(nil)
        let receivedURL = LockIsolated<URL?>(nil)
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: Self.connectedTarget()
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.pushFileWithProgress = { url, path, _, _ in
                receivedURL.setValue(url)
                pushedPath.setValue(path)
            }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFile(url: localURL, fileName: "large-upload.bin"))
        await store.receive(\.pushFileResolved) {
            $0.errorMessage = nil
            $0.activeBackgroundOperationID = uploadID
            $0.activeTransferRemotePath = "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp"
        }
        await store.receive(\.delegate)
        await store.receive(\.backgroundOperationCompleted) {
            $0.activeBackgroundOperationID = nil
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.delegate)
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }

        #expect(receivedURL.value == localURL)
        #expect(pushedPath.value == "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp")
    }

    @Test
    func cancellingUploadRestoresUIAndRemovesPartialRemoteFile() async {
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let temporaryPath = "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp"
        let cleanupCommand = LockIsolated<String?>(nil)
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: Self.connectedTarget()
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { command in
                if command.hasPrefix("if [ -e") {
                    try await Task.sleep(for: .seconds(60))
                } else {
                    cleanupCommand.setValue(command)
                }
                return ""
            }
            $0.adbClient.pushFileWithProgress = { _, _, _, _ in }
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFile(
            url: URL(fileURLWithPath: "/tmp/upload.bin"),
            fileName: "upload.bin"
        ))
        await store.receive(\.pushFileResolved) {
            $0.errorMessage = nil
            $0.activeBackgroundOperationID = uploadID
            $0.activeTransferRemotePath = temporaryPath
        }
        await store.receive(\.delegate)
        await store.send(.cancelCurrentOperation) {
            $0.fileLoadPurpose = nil
            $0.activeBackgroundOperationID = nil
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.transferCleanupCompleted)
        await store.receive(\.delegate)

        #expect(cleanupCommand.value == "rm -rf '\(temporaryPath)'")
    }

    @Test
    func activeTransferDoesNotBlockDirectoryNavigation() async {
        let transferID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
        let store = TestStore(initialState: FileManagerFeature.State(
            activeBackgroundOperationID: transferID,
            activeTransferRemotePath: "/sdcard/.iadb-upload.tmp"
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.navigateToPath("/sdcard/Download")) {
            $0.pathHistory.append("/sdcard/Download")
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
            $0.currentPath = "/sdcard/Download"
        }
        #expect(store.state.activeBackgroundOperationID == transferID)
    }

    @Test
    func reducerOwnedRenameFormValidatesInlineAndDismissesWithoutMutation() async {
        let entry = FileEntry(
            name: "report.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "sdcard_rw",
            size: "42",
            date: "2026-07-13",
            time: "03:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/report.txt"
        )
        let store = TestStore(initialState: FileManagerFeature.State(
            selectedFile: entry,
            showingFileActions: true
        )) {
            FileManagerFeature()
        }

        await store.send(.presentForm(.rename(entry))) {
            $0.showingFileActions = false
            $0.presentedForm = .init(
                kind: .rename(entry),
                input: "report.txt",
                validationMessage: "Enter a different name."
            )
        }
        await store.send(.formInputChanged("bad/name")) {
            $0.presentedForm?.input = "bad/name"
            $0.presentedForm?.validationMessage = "Name cannot contain '/'."
        }
        await store.send(.submitForm)
        #expect(store.state.presentedForm != nil)
        #expect(store.state.activeMutation == nil)

        await store.send(.formInputChanged("renamed.txt")) {
            $0.presentedForm?.input = "renamed.txt"
            $0.presentedForm?.validationMessage = nil
        }
        await store.send(.dismissForm) {
            $0.presentedForm = nil
        }
    }

    @Test
    func activeMutationDoesNotBlockDirectoryNavigation() async {
        let store = TestStore(initialState: FileManagerFeature.State(
            activeMutation: .init(kind: .create, objectName: "notes.txt")
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.navigateToPath("/sdcard/Download")) {
            $0.pathHistory.append("/sdcard/Download")
        }
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.currentPath = "/sdcard/Download"
        }
        #expect(store.state.activeMutation == .init(kind: .create, objectName: "notes.txt"))
    }

    @Test
    func refreshKeepsPreviousDirectorySnapshotVisible() async {
        let existing = FileEntry(
            name: "existing.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "sdcard_rw",
            size: "1",
            date: "2026-07-13",
            time: "03:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/existing.txt"
        )
        let store = TestStore(initialState: FileManagerFeature.State(entries: [existing])) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.loadDirectory(path: nil)) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        #expect(store.state.entries == [existing])
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = []
        }
    }

    @Test
    func uploadReviewNamesTargetAndKeepBothResolvesConflictBeforeTransfer() async {
        let existing = FileEntry(
            name: "report.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "sdcard_rw",
            size: "10",
            date: "2026-07-13",
            time: "03:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/report.txt"
        )
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000077")!
        let commands = LockIsolated<[String]>([])
        let target = Self.connectedTarget()
        let localURL = URL(fileURLWithPath: "/tmp/report.txt")
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: target,
            entries: [existing]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.uuid = .constant(operationID)
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.adbClient.pushFileWithProgress = { _, _, _, _ in }
            $0.adbClient.shell = { command in
                commands.withValue { $0.append(command) }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [existing] }
        }

        await store.send(.reviewUpload(url: localURL, fileName: "report.txt")) {
            $0.uploadReview = .init(
                id: operationID,
                localURL: localURL,
                originalFileName: "report.txt",
                destinationFileName: "report.txt",
                totalBytes: nil,
                target: target,
                hasConflict: true,
                conflictPolicy: .cancel
            )
        }
        await store.send(.confirmUpload)
        #expect(store.state.uploadReview?.conflictPolicy == .cancel)
        await store.send(.setUploadConflictPolicy(.keepBoth)) {
            $0.uploadReview?.conflictPolicy = .keepBoth
        }
        await store.send(.confirmUpload) {
            $0.uploadReview = nil
        }
        await store.receive(\.pushFileResolved) {
            $0.errorMessage = nil
            $0.activeBackgroundOperationID = operationID
            $0.activeTransferRemotePath = "/sdcard/.iadb-upload-\(operationID.uuidString).tmp"
        }
        await store.receive(\.delegate)
        await store.receive(\.backgroundOperationCompleted) {
            $0.activeBackgroundOperationID = nil
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.delegate)
        await store.receive(\.loadDirectory) {
            $0.isDirectoryLoading = true
            $0.directoryLoadGeneration = 1
            $0.activeDirectoryLoadGeneration = 1
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isDirectoryLoading = false
            $0.activeDirectoryLoadGeneration = nil
            $0.entries = [existing]
        }

        #expect(commands.value.contains { $0.contains("'/sdcard/report 2.txt'") })
    }

    @Test
    func bulkMoveUsesPerItemCommandsAndKeepsFailedItemSelected() async {
        let first = FileEntry(
            name: "first.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "1", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/first.txt"
        )
        let second = FileEntry(
            name: "second.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "2", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/second.txt"
        )
        let commands = LockIsolated<[String]>([])
        let store = TestStore(initialState: FileManagerFeature.State(
            entries: [first, second],
            isSelectionMode: true,
            selectedEntryPaths: [first.fullPath, second.fullPath]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { command in
                commands.withValue { $0.append(command) }
                if command.contains("second.txt") {
                    throw ADBError.commandFailed("Permission denied")
                }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [second] }
        }
        store.exhaustivity = .off

        await store.send(.moveSelectedFiles(destinationDirectory: "/sdcard/Archive"))
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkOperationCompleted)
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)
        store.exhaustivity = .on

        #expect(commands.value.count == 2)
        #expect(commands.value[0].contains("first.txt"))
        #expect(!commands.value[0].contains("second.txt"))
        #expect(commands.value[1].contains("second.txt"))
        #expect(store.state.selectedEntryPaths == [second.fullPath])
        #expect(store.state.operationSummary == "1 succeeded, 1 failed")
    }

    @Test
    func bulkDuplicateTracksEachObjectIndependently() async {
        let first = FileEntry(
            name: "one.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "1", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/one.txt"
        )
        let second = FileEntry(
            name: "two.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "2", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/two.txt"
        )
        let commands = LockIsolated<[String]>([])
        let store = TestStore(initialState: FileManagerFeature.State(
            entries: [first, second],
            isSelectionMode: true,
            selectedEntryPaths: [first.fullPath, second.fullPath]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000088")!)
            $0.adbClient.shell = { command in
                commands.withValue { $0.append(command) }
                return ""
            }
            $0.adbClient.listDirectoryEntries = { _ in [first, second] }
        }
        store.exhaustivity = .off

        await store.send(.duplicateSelectedFiles)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkItemCompleted)
        await store.receive(\.bulkOperationCompleted)
        await store.receive(\.loadDirectory)
        await store.receive(\.directoryLoaded)
        store.exhaustivity = .on

        #expect(commands.value.count == 2)
        #expect(commands.value[0].contains("one.txt"))
        #expect(!commands.value[0].contains("two.txt"))
        #expect(commands.value[1].contains("two.txt"))
        #expect(store.state.selectedEntryPaths.isEmpty)
        #expect(store.state.operationSummary == "2 succeeded, 0 failed")
    }

    @Test
    func bulkDownloadKeepsSelectionAndPublishesShareableLocalURLs() async {
        let first = FileEntry(
            name: "one.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "1", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/one.txt"
        )
        let second = FileEntry(
            name: "two.txt", permissions: "-rw-r--r--", owner: "shell", group: "shell",
            size: "2", date: "2026-07-13", time: "03:00", isDirectory: false,
            isSymlink: false, symlinkTarget: nil, fullPath: "/sdcard/two.txt"
        )
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let destinations = LockIsolated<[URL]>([])
        let selectedPaths: Set<String> = [first.fullPath, second.fullPath]
        let store = TestStore(initialState: FileManagerFeature.State(
            remoteTarget: Self.connectedTarget(),
            entries: [first, second],
            isSelectionMode: true,
            selectedEntryPaths: selectedPaths
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.uuid = .constant(operationID)
            $0.date.now = Date(timeIntervalSince1970: 1_000)
            $0.adbClient.pullFileToWithProgress = { _, destination, _ in
                destinations.withValue { $0.append(destination) }
            }
        }
        store.exhaustivity = .off

        await store.send(.downloadSelectedFiles)
        await store.receive(\.delegate)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkDownloadItemCompleted)
        await store.receive(\.bulkItemStarted)
        await store.receive(\.bulkDownloadItemCompleted)
        await store.receive(\.transferProgress)
        await store.receive(\.delegate)
        await store.receive(\.bulkOperationCompleted)
        await store.receive(\.bulkDownloadCompleted)
        await store.receive(\.delegate)
        store.exhaustivity = .on

        #expect(destinations.value.map(\.lastPathComponent) == ["one.txt", "two.txt"])
        #expect(store.state.downloadedFileURLs.map(\.lastPathComponent) == ["one.txt", "two.txt"])
        #expect(store.state.selectedEntryPaths == selectedPaths)
        #expect(store.state.isSelectionMode)
        #expect(store.state.operationSummary == "2 succeeded, 0 failed")

        await store.send(.clearDownloadedFiles) {
            $0.downloadedFileURLs = []
            $0.activeDownloadDirectoryURL = nil
        }
    }
}
