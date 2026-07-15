import ComposableArchitecture
import Foundation
import Testing
import UIKit
@testable import iADB

@MainActor
struct PerformanceScenarioTests {
    @Test
    func filesTenThousandEntriesSortAndFilterWithinBound() async {
        var entries: [FileEntry] = []
        entries.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let entry = FileEntry(
                name: String(format: "file-%05d.log", index),
                permissions: index.isMultiple(of: 100) ? "drwxr-xr-x" : "-rw-r--r--",
                owner: "shell",
                group: "shell",
                size: String((10_000 - index) * 1_024),
                date: "2026-07-13",
                time: String(format: "%02d:%02d", (index / 60) % 24, index % 60),
                isDirectory: index.isMultiple(of: 100),
                isSymlink: false,
                symlinkTarget: nil,
                fullPath: String(format: "/sdcard/Download/file-%05d.log", index)
            )
            entries.append(entry)
        }
        var state = FileManagerFeature.State(entries: entries)

        let clock = ContinuousClock()
        let start = clock.now
        state.sort = .sizeDescending
        state.entries = FileManagerFeature.sorted(state.entries, by: state.sort)
        state.searchQuery = "0999"
        let filtered = state.visibleEntries
        let elapsed = start.duration(to: clock.now)

        #expect(state.entries.count == 10_000)
        #expect(state.entries.prefix(100).allSatisfy { $0.isDirectory })
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0.fullPath.localizedCaseInsensitiveContains("0999") })
        #expect(elapsed < .seconds(3))
    }

    @Test
    func appsTwoThousandPackagesFilterAndSortWithinBound() {
        let apps = (0..<2_000).map { index -> AppInfo in
            var app = AppInfo(
                packageName: String(format: "com.example.package.%04d", index),
                isSystemApp: index.isMultiple(of: 5)
            )
            app.appName = String(format: "Utility %04d", 2_000 - index)
            app.versionName = "1.\(index % 10)"
            return app
        }
        var state = AppsFeature.State(
            apps: apps,
            filter: .all,
            sort: .package,
            searchText: "package.019"
        )
        let clock = ContinuousClock()
        let start = clock.now
        let filtered = state.filteredApps
        let elapsed = start.duration(to: clock.now)

        #expect(filtered.count == 10)
        #expect(filtered.map(\.packageName) == filtered.map(\.packageName).sorted())
        #expect(elapsed < .seconds(2))

        state.filter = .user
        #expect(state.filteredApps.allSatisfy { !$0.isSystemApp })
    }

    @Test
    func shellFiftyCommandsFillButNeverExceedHistoryBudget() {
        let outputBytes = ShellFeature.maximumHistoryBytes / 50 - 128
        let entries = (0..<50).map { index in
            ShellHistoryEntry(
                command: "command-\(index)",
                output: String(repeating: "x", count: outputBytes),
                timestamp: Date(timeIntervalSince1970: TimeInterval(50 - index)),
                isError: false,
                originDeviceID: "guid:performance",
                exitCode: 0,
                duration: 0.01
            )
        }
        let retained = ShellFeature.retainedHistory(entries)
        let retainedBytes = retained.reduce(0) { partial, entry in
            partial + entry.command.utf8.count + entry.output.utf8.count
        }
        let maximumOutput = String(repeating: "y", count: ShellFeature.maximumEntryOutputBytes + 1)

        #expect(retained.count == 50)
        #expect(retainedBytes <= ShellFeature.maximumHistoryBytes)
        #expect(ShellFeature.truncatedOutput(maximumOutput).contains("Output truncated by iADB"))
    }

    @Test
    func logcatThirtyMinuteCaptureKeepsFiveThousandOrderedEntries() {
        let clock = ContinuousClock()
        let start = clock.now
        var retained: [LogEntry] = []
        var dropped = 0

        // Ten lines per second for 30 minutes, delivered in one-minute batches.
        for minute in 0..<30 {
            let batch = (0..<600).map { offset in
                let index = minute * 600 + offset
                return LogEntry(
                    timestamp: String(format: "07-13 08:%02d:%02d.%03d", minute % 60, offset / 10, (offset % 10) * 100),
                    pid: "1000",
                    tid: String(1_000 + index % 8),
                    level: index.isMultiple(of: 17) ? .warning : .info,
                    tag: "Performance",
                    message: String(format: "event-%05d", index)
                )
            }
            let result = LogcatFeature.appendingToRing(
                batch,
                existing: retained,
                countLimit: 5_000,
                byteLimit: LogcatFeature.maximumRetainedBytes
            )
            retained = result.entries
            dropped += result.dropped
        }

        var fragment = LogcatChunkBuffer()
        _ = appendLogcatChunk(Data(repeating: 0x61, count: 200_000), to: &fragment, lineByteLimit: 1_024)
        let oversized = appendLogcatChunk(Data([0x0A]), to: &fragment, lineByteLimit: 1_024)
        let retainedBytes = retained.reduce(0) {
            $0 + LogcatFeature.serializedLine($1).utf8.count + 1
        }
        let elapsed = start.duration(to: clock.now)

        #expect(retained.count == 5_000)
        #expect(dropped == 13_000)
        #expect(retained.first?.message == "event-13000")
        #expect(retained.last?.message == "event-17999")
        #expect(retainedBytes <= LogcatFeature.maximumRetainedBytes)
        #expect(fragment.data.isEmpty)
        #expect(oversized.first?.contains("truncated") == true)
        #expect(elapsed < .seconds(5))
    }

    @Test
    func screenshotsStopExactlyAtHundredMegabyteBoundaryAndReuseDecode() throws {
        let twoMegabytes = Data(repeating: 0xA5, count: 2 * 1_024 * 1_024)
        let entries = (0..<51).map { index in
            ScreenshotFeature.ScreenshotEntry(
                id: deterministicUUID(index),
                timestamp: Date(timeIntervalSince1970: TimeInterval(51 - index)),
                data: twoMegabytes,
                originDeviceID: "guid:performance",
                originDeviceName: "Performance Android",
                pixelWidth: 1_080,
                pixelHeight: 2_400,
                byteCount: twoMegabytes.count
            )
        }
        let retained = ScreenshotFeature.retainedScreenshots(
            entries,
            countLimit: 100,
            byteLimit: screenshotStorageByteLimit
        )

        #expect(retained.count == 50)
        #expect(retained.reduce(0) { $0 + $1.data.count } == screenshotStorageByteLimit)
        #expect(retained.last?.id == entries[49].id)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let png = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let cacheEntry = ScreenshotFeature.ScreenshotEntry(
            id: deterministicUUID(99),
            timestamp: Date(),
            data: png,
            pixelWidth: 2,
            pixelHeight: 2
        )
        let cache = ScreenshotImageCache(countLimit: 2, totalCostLimit: 1_024 * 1_024)
        let first = try #require(cache.image(for: cacheEntry))
        let second = try #require(cache.image(for: cacheEntry))
        #expect(first === second)
    }

    @Test
    func threeActivitiesAndRapidRootSwitchingRemainStable() async {
        let first = operation(id: 1, deviceID: "device-a", kind: .upload)
        let second = operation(id: 2, deviceID: "device-a", kind: .installAPK)
        let third = operation(id: 3, deviceID: "device-b", kind: .capture)
        var state = AppFeature.State()
        state.operations.operations = [first, second, third]
        let store = TestStore(initialState: state) { AppFeature() }
        store.exhaustivity = .off
        let roots = AppShellFeature.Root.allCases
        let clock = ContinuousClock()
        let start = clock.now

        for index in 0..<250 {
            await store.send(.appShell(.selectRoot(roots[index % roots.count])))
        }
        let elapsed = start.duration(to: clock.now)

        #expect(store.state.operations.operations == [first, second, third])
        #expect(store.state.operations.activeCount == 3)
        #expect(elapsed < .seconds(5))
    }

    @Test
    func disconnectDuringUploadInstallAndLogCaptureKeepsUserContext() async {
        let uploadID = deterministicUUID(201)
        let installID = deterministicUUID(202)
        let identity = DeviceIdentity(
            stableID: "guid:performance",
            displayName: "Performance Android",
            adbFingerprint: "performance"
        )
        let file = FileEntry(
            name: "retained.txt",
            permissions: "-rw-r--r--",
            owner: "shell",
            group: "shell",
            size: "42",
            date: "2026-07-13",
            time: "08:00",
            isDirectory: false,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/Download/retained.txt"
        )
        var state = AppFeature.State()
        state.appShell.selectedRoot = .files
        state.connection.connectionState = .connected
        state.connection.connectionGeneration = 1
        state.connection.activeConnectionGeneration = 1
        state.session.selectedDevice = identity
        state.session.transport = .connected(
            endpoint: Endpoint(host: "192.0.2.10", port: 37141),
            since: Date(timeIntervalSince1970: 10)
        )
        for workspace in [
            RemoteWorkspaceSnapshot.files,
            .apps,
            .logcat,
        ] {
            state.session.remoteSnapshots[workspace] = RemoteSnapshotRelationship(
                deviceID: identity.stableID,
                fetchedAt: Date(timeIntervalSince1970: 10),
                isStale: false
            )
        }
        state.fileManager.currentPath = "/sdcard/Download"
        state.fileManager.entries = [file]
        state.fileManager.activeBackgroundOperationID = uploadID
        state.fileManager.activeTransferRemotePath = "/sdcard/Download/.upload.tmp"
        state.apps.apps = [AppInfo(packageName: "com.example.retained")]
        state.apps.isInstalling = true
        state.apps.activeInstallID = installID
        state.apps.activeInstallRemotePath = "/data/local/tmp/install.apk"
        state.logcat.entries = [LogEntry(
            timestamp: "07-13 08:00:00.000",
            pid: "1000",
            tid: "1001",
            level: .info,
            tag: "Retained",
            message: "before disconnect"
        )]
        state.logcat.captureState = .live
        state.logcat.activeCaptureGeneration = 1
        state.operations.operations = [
            operation(id: 201, deviceID: identity.stableID, kind: .upload),
            operation(id: 202, deviceID: identity.stableID, kind: .installAPK),
        ]
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 20))
            $0.adbClient.disconnect = {}
            $0.adbClient.shell = { _ in "" }
        }
        store.exhaustivity = .off

        await store.send(.connection(.connectionLost(generation: 1, "Wi-Fi changed")))
        await store.skipReceivedActions()

        #expect(store.state.appShell.selectedRoot == .files)
        #expect(store.state.fileManager.currentPath == "/sdcard/Download")
        #expect(store.state.fileManager.entries == [file])
        #expect(store.state.fileManager.activeBackgroundOperationID == nil)
        #expect(store.state.apps.apps.map(\.packageName) == ["com.example.retained"])
        #expect(!store.state.apps.isInstalling)
        #expect(store.state.logcat.entries.first?.message == "before disconnect")
        #expect(store.state.logcat.captureState == .stopped)
        #expect(store.state.operations.operations.allSatisfy { !$0.isActive })
        #expect(store.state.session.remoteSnapshots.values.allSatisfy { $0.isStale })
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func operation(
        id: Int,
        deviceID: String,
        kind: BackgroundOperation.Kind
    ) -> BackgroundOperation {
        BackgroundOperation(
            id: deterministicUUID(id),
            deviceID: deviceID,
            deviceName: "Performance Android",
            workspace: kind == .installAPK ? .apps : kind == .capture ? .screens : .files,
            kind: kind,
            objectName: "operation-\(id)",
            phase: .running,
            completedUnits: 1,
            totalUnits: 100,
            detail: "In progress",
            isCancellable: true,
            isTransportDependent: true,
            cleanupState: .notRequired,
            outcome: nil,
            retryPayload: nil,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: nil
        )
    }
}
