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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.showingFileActions = false
            $0.fileLoadPurpose = .preview
        }
        await store.receive(\.fileLoaded.success) {
            $0.isLoading = false
            $0.previewFileData = fileData
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
            $0.adbClient.pullFileTo = { _, url in downloadURL.setValue(url) }
            $0.uuid = .constant(downloadID)
        }

        await store.send(.downloadSelectedFile) {
            $0.isLoading = true
            $0.showingFileActions = false
            $0.fileLoadPurpose = .download
            $0.activeDownloadDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iADBDownloads", isDirectory: true)
                .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        }

        await store.receive(\.fileDownloaded.success) {
            $0.isLoading = false
            $0.downloadedFileURL = downloadURL.value
            $0.activeDownloadDirectoryURL = nil
        }
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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            showingFilePreview: true,
            fileLoadPurpose: .preview
        )) {
            FileManagerFeature()
        }

        await store.send(.dismissPreview) {
            $0.previewFileData = nil
            $0.showingFilePreview = false
            $0.fileLoadPurpose = nil
            $0.selectedFile = nil
        }
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

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.deleteFile(file)) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.operationCompleted) {
            $0.isLoading = false
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand.value?.contains("old.txt") == true)
    }

    @Test
    func deleteSelectedFiles() async {
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

        let store = TestStore(initialState: FileManagerFeature.State(
            entries: [file, dir],
            isSelectionMode: true,
            selectedEntryPaths: [file.fullPath, dir.fullPath]
        )) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand.setValue(cmd); return "" }
            $0.adbClient.listDirectoryEntries = { _ in [] }
        }

        await store.send(.deleteSelectedFiles) {
            $0.isSelectionMode = false
            $0.selectedEntryPaths = []
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.operationCompleted) {
            $0.isLoading = false
        }
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand.value == "rm '/sdcard/old.txt' && rm -rf '/sdcard/Docs'")
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
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.operationCompleted) {
            $0.isLoading = false
        }
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.operationCompleted) {
            $0.isLoading = false
        }
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-copy-\(copyID.uuidString).tmp"
        }
        await store.receive(\.operationCompleted) {
            $0.isLoading = false
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.operationCompleted) {
            $0.isLoading = false
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
            $0.isLoading = true
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-create-\(createID.uuidString).tmp"
        }

        await store.receive(\.operationCompleted) {
            $0.isLoading = false
            $0.activeTransferRemotePath = nil
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
        #expect(store.state.isLoading == false)
        #expect(store.state.showingFileActions)
    }

    @Test
    func pushFileData() async {
        let pushedPath = LockIsolated<String?>(nil)
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.pushData = { _, path, _ in pushedPath.setValue(path) }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFileData(data: Data([1, 2, 3]), fileName: "upload.bin")) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp"
        }

        await store.receive(\.operationCompleted) {
            $0.isLoading = false
            $0.activeTransferRemotePath = nil
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
        )) {
            $0.errorMessage = "The selected file name is not supported on Android."
        }
    }

    @Test
    func streamsImportedFileWithoutLoadingItIntoMemory() async {
        let localURL = URL(fileURLWithPath: "/tmp/large-upload.bin")
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let pushedPath = LockIsolated<String?>(nil)
        let receivedURL = LockIsolated<URL?>(nil)
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "" }
            $0.adbClient.pushFile = { url, path, _ in
                receivedURL.setValue(url)
                pushedPath.setValue(path)
            }
            $0.adbClient.listDirectoryEntries = { _ in [] }
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFile(url: localURL, fileName: "large-upload.bin")) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.activeTransferRemotePath = "/sdcard/.iadb-upload-\(uploadID.uuidString).tmp"
        }
        await store.receive(\.operationCompleted) {
            $0.isLoading = false
            $0.activeTransferRemotePath = nil
        }
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
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
        let store = TestStore(initialState: FileManagerFeature.State()) {
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
            $0.adbClient.pushFile = { _, _, _ in }
            $0.uuid = .constant(uploadID)
        }

        await store.send(.pushFile(
            url: URL(fileURLWithPath: "/tmp/upload.bin"),
            fileName: "upload.bin"
        )) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.activeTransferRemotePath = temporaryPath
        }
        await store.send(.cancelCurrentOperation) {
            $0.isLoading = false
            $0.fileLoadPurpose = nil
            $0.activeTransferRemotePath = nil
        }
        await store.finish()

        #expect(cleanupCommand.value == "rm -rf '\(temporaryPath)'")
    }
}
