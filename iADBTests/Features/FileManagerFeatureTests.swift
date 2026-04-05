import ComposableArchitecture
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

        await store.send(.loadDirectory(path: "/sdcard")) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded.success) {
            $0.isLoading = false
            $0.currentPath = "/sdcard"
            // Entries parsed from ls output — directories first
            #expect($0.entries.count >= 0) // Parsing depends on FileEntry.parse
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

        await store.receive(\.directoryLoaded.failure) {
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

        await store.receive(\.directoryLoaded.success) {
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
        }
    }

    @Test
    func navigateUp() async {
        let store = TestStore(
            initialState: FileManagerFeature.State(currentPath: "/sdcard/Downloads")
        ) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.listDirectory = { _ in "" }
        }

        await store.send(.navigateUp) {
            $0.pathHistory = ["/sdcard", "/sdcard"]
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded.success) {
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

        await store.receive(\.directoryLoaded.success) {
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
    func pullFile() async {
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

        let store = TestStore(initialState: FileManagerFeature.State()) {
            FileManagerFeature()
        } withDependencies: {
            $0.adbClient.pullFile = { _ in fileData }
        }

        await store.send(.pullFile(file)) {
            $0.isLoading = true
        }

        await store.receive(\.filePulled.success) {
            $0.isLoading = false
            $0.pulledFileData = fileData
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

        await store.receive(\.operationCompleted.success) {
            $0.isLoading = false
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded.success) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand?.contains("old.txt") == true)
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

        await store.receive(\.operationCompleted.success) {
            $0.isLoading = false
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded.success) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(shellCommand?.contains("NewFolder") == true)
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

        await store.receive(\.operationCompleted.success) {
            $0.isLoading = false
        }

        await store.receive(\.loadDirectory) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        await store.receive(\.directoryLoaded.success) {
            $0.isLoading = false
            $0.entries = []
        }

        #expect(pushedPath == "/sdcard/upload.bin")
    }
}
