import ComposableArchitecture
import Foundation
import XCTest
@testable import iADB

@MainActor
final class BusinessFeatureTests: XCTestCase {
    func testAppsLoadNormalizesPackageList() async {
        var state = AppsFeature.State()
        state.isLoading = true
        let store = TestStore(initialState: state) { AppsFeature() }

        await store.send(.loaded(.success(["z.package", "a.package", "z.package"]))) {
            $0.isLoading = false
            $0.apps = [AppInfo(packageName: "a.package"), AppInfo(packageName: "z.package")]
        }
    }

    func testFileLoadSortsDirectoriesBeforeFiles() async {
        var state = FileManagerFeature.State()
        state.isLoading = true
        let directory = file("folder", isDirectory: true)
        let file = file("alpha.txt")
        let store = TestStore(initialState: state) { FileManagerFeature() }

        await store.send(.loaded(path: "/sdcard", .success([file, directory]))) {
            $0.isLoading = false
            $0.entries = [directory, file]
        }
    }

    func testLogcatKeepsBoundedRecentEntries() async {
        let old = log("old")
        var state = LogcatFeature.State()
        state.entries = Array(repeating: old, count: 5_000)
        let recent = log("recent")
        let store = TestStore(initialState: state) { LogcatFeature() }

        await store.send(.received([recent])) {
            $0.entries.removeFirst()
            $0.entries.append(recent)
        }
    }

    func testPairingRejectsIncompleteInputWithoutStartingNetworkWork() async {
        let store = TestStore(initialState: PairingFeature.State()) { PairingFeature() }

        await store.send(.pair) {
            $0.errorMessage = "Invalid pairing address or code"
        }
    }

    private func file(_ name: String, isDirectory: Bool = false) -> FileEntry {
        FileEntry(
            name: name,
            permissions: isDirectory ? "drwxr-xr-x" : "-rw-r--r--",
            owner: "root",
            group: "root",
            size: "0",
            date: "2026-08-16",
            time: "12:00",
            isDirectory: isDirectory,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/\(name)"
        )
    }

    private func log(_ message: String) -> LogEntry {
        LogEntry(timestamp: "", pid: "", tid: "", level: .info, tag: "test", message: message)
    }
}
