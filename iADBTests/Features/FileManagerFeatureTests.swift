import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct FileManagerFeatureTests {
    private static let lsOutput = """
    drwxr-xr-x  2 root root 4096 2024-01-01 00:00 Documents
    -rw-r--r--  1 root root 1234 2024-01-01 00:00 file.txt
    """

    @Test
    func loadDirectorySuccess() async {
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectory = { _ in Self.lsOutput }
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
            $0.adbClient.listDirectory = { _ in throw ADBError.notConnected }
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
            $0.adbClient.listDirectory = { _ in "" }
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
            $0.adbClient.pullFile = { _ in fileData }
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
        let fileData = Data([0xFF, 0xD8, 0xFF, 0xE0])

        let store = TestStore(
            initialState: FileManagerFeature.State(selectedFile: file, showingFileActions: true)
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.pullFile = { _ in fileData }
        }

        await store.send(.downloadSelectedFile) {
            $0.isLoading = true
            $0.showingFileActions = false
            $0.fileLoadPurpose = .download
        }

        await store.receive(\.fileLoaded.success) {
            $0.isLoading = false
            $0.downloadedFileData = fileData
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
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.navigateUp) {
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
    func goBack() async {
        let store = TestStore(
            initialState: FileManagerFeature.State(
                currentPath: "/sdcard/Downloads",
                pathHistory: ["/sdcard", "/sdcard/Downloads"]
            )
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectory = { _ in "" }
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
        }
    }

    @Test
    func clearDownloadedFile() async {
        let store = TestStore(initialState: FileManagerFeature.State(
            downloadedFileData: Data([0x01]),
            fileLoadPurpose: .download
        )) {
            FileManagerFeature()
        }

        await store.send(.clearDownloadedFile) {
            $0.downloadedFileData = nil
            $0.fileLoadPurpose = nil
        }
    }

    @Test
    func deleteFile() async {
        var shellCommand: String?
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
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.deleteFile(file))

        await store.receive(\.operationCompleted)

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand?.contains("old.txt") == true)
    }

    @Test
    func deleteSelectedFiles() async {
        var shellCommand: String?
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
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.deleteSelectedFiles) {
            $0.isSelectionMode = false
            $0.selectedEntryPaths = []
        }

        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand == "rm \"/sdcard/old.txt\" && rm -rf \"/sdcard/Docs\"")
    }

    @Test
    func renameFile() async {
        var shellCommand: String?
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
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.renameFile(file, newName: "new.txt"))
        await store.receive(\.moveFile)
        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand == "mv \"/sdcard/old.txt\" \"/sdcard/new.txt\"")
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
        var shellCommand: String?
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
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.moveFile(file, destinationPath: "/sdcard/Documents/old.txt"))
        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand == "mv \"/sdcard/old.txt\" \"/sdcard/Documents/old.txt\"")
    }

    @Test
    func duplicateFile() async {
        var shellCommand: String?
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
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.duplicateFile(file))
        await store.receive(\.operationCompleted)
        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand == "cp \"/sdcard/photo.jpg\" \"/sdcard/photo copy.jpg\"")
    }

    @Test
    func createDirectory() async {
        var shellCommand: String?
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.createDirectory(name: "NewFolder"))

        await store.receive(\.operationCompleted)

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand?.contains("NewFolder") == true)
    }

    @Test
    func createFile() async {
        var shellCommand: String?
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in shellCommand = cmd; return "" }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.createFile(name: "notes.txt"))

        await store.receive(\.operationCompleted)

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand == "touch \"/sdcard/notes.txt\"")
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
    func pushFileData() async {
        var pushedPath: String?
        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.pushData = { _, path, _ in pushedPath = path }
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.pushFileData(data: Data([1, 2, 3]), fileName: "upload.bin")) {
            $0.isLoading = true
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

        #expect(pushedPath == "/sdcard/upload.bin")
    }
}
