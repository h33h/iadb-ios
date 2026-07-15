#if DEBUG
import Foundation
import UIKit

enum AppFixture: String, CaseIterable {
    case firstLaunch = "first-launch"
    case scanning
    case pairing
    case connecting
    case connected
    case disconnected
    case reconnecting
    case loading
    case empty
    case partialData = "partial-data"
    case fileUploadProgress = "file-upload-progress"
    case operationProgress = "operation-progress"
    case commandProgress = "command-progress"
    case success
    case validationError = "validation-error"
    case connectionError = "connection-error"
    case permissionDenied = "permission-denied"
    case destructiveConfirmation = "destructive-confirmation"
    case partialBulkFailure = "partial-bulk-failure"
}

enum AppStoreDemo {
    static let device = DiscoveredDevice(
        id: "demo-android-001",
        name: "Demo Android",
        host: "192.168.50.42",
        port: 37141,
        isPaired: true
    )

    static let pairedDevice = PairedDevice(
        name: "Demo Android",
        guid: device.id,
        lastHost: device.host,
        serviceName: device.id
    )

    static var initialState: AppFeature.State {
        var state = AppFeature.State()
        state.hasEnteredWorkspace = true
        state.selectedTab = .device
        state.connection = ConnectionFeature.State(
            discoveredDevices: [device],
            pairedDevices: [pairedDevice],
            connectionState: .connected,
            lastConnectionDevice: device,
            connectionGeneration: 1,
            activeConnectionGeneration: 1
        )
        let identity = DeviceIdentity.resolved(from: device, pairedDevices: [pairedDevice])
        let endpoint = Endpoint(host: device.host, port: device.port)
        let contactDate = Date(timeIntervalSince1970: 1_783_844_470)
        state.session.selectedDevice = identity
        state.session.transport = .connected(endpoint: endpoint, since: contactDate)
        state.session.lastKnownEndpoint = endpoint
        state.session.lastSuccessfulContact = contactDate
        state.session.capabilities = .connected
        for workspace in [
            RemoteWorkspaceSnapshot.device,
            .files,
            .apps,
            .logcat,
        ] {
            state.session.remoteSnapshots[workspace] = RemoteSnapshotRelationship(
                deviceID: identity.stableID,
                fetchedAt: contactDate,
                isStale: false
            )
        }

        var details = DeviceDetails()
        details.model = "Studio Android"
        details.manufacturer = "Demo Labs"
        details.androidVersion = "16"
        details.sdkVersion = "36"
        details.serialNumber = "DEMO-ANDROID-001"
        details.buildFingerprint = "demo/studio/device:16/DEMO.2026:user/release-keys"
        details.batteryLevel = "82%"
        details.batteryStatus = "Charging"
        details.screenResolution = "1080×2400"
        details.ipAddress = device.host
        details.totalMemory = "8.0 GB"
        details.availableMemory = "5.4 GB"
        details.totalStorage = "256 GB"
        details.availableStorage = "173 GB"
        details.cpuAbi = "arm64-v8a"
        details.deviceName = "studio"
        state.device.details = details

        state.fileManager.currentPath = "/sdcard/Download"
        state.fileManager.pathHistory = ["/sdcard", "/sdcard/Download"]
        state.fileManager.entries = demoFiles

        state.apps.apps = demoApps
        state.apps.filter = .user
        state.apps.remoteTarget = RemoteDeviceTarget(
            deviceID: identity.stableID,
            deviceName: identity.displayName,
            transportGeneration: 1,
            switchedAt: contactDate,
            isConnected: true
        )
        state.fileManager.remoteTarget = state.apps.remoteTarget
        state.device.remoteTarget = state.apps.remoteTarget

        let scopedHistory = shellHistory.map {
            ShellHistoryEntry(
                id: $0.id,
                command: $0.command,
                output: $0.output,
                timestamp: $0.timestamp,
                isError: $0.isError,
                originDeviceID: identity.stableID,
                stdout: $0.stdout,
                stderr: $0.stderr,
                exitCode: $0.exitCode,
                duration: $0.duration,
                wasTruncated: $0.wasTruncated,
                usedLegacyFallback: $0.usedLegacyFallback
            )
        }
        state.shell.activeDeviceID = identity.stableID
        state.shell.history = scopedHistory
        state.shell.allHistory = scopedHistory
        state.shell.pinnedCommands = ["df -h /sdcard", "getprop ro.build.version.release"]
        state.shell.allPinnedCommands = state.shell.pinnedCommands.map {
            DeviceScopedPinnedCommand(command: $0, originDeviceID: identity.stableID)
        }
        state.shell.didLoadPersistence = true

        state.logcat.entries = demoLogs
        state.logcat.captureState = .live
        state.logcat.didLoadPersistence = true
        state.logcat.activeDeviceID = identity.stableID
        state.logcat.savedPresets = [
            LogcatPreset(
                name: "App lifecycle",
                filterText: "DemoActivity",
                level: nil,
                originDeviceID: identity.stableID
            ),
            LogcatPreset(
                name: "Warnings",
                filterText: "",
                level: .warning,
                originDeviceID: identity.stableID
            ),
        ]
        state.logcat.allSavedPresets = state.logcat.savedPresets

        state.screenshot.activeDeviceID = identity.stableID
        state.screenshot.activeDeviceName = identity.displayName
        state.screenshot.screenshots = demoScreenshots.map {
            ScreenshotFeature.ScreenshotEntry(
                id: $0.id,
                timestamp: $0.timestamp,
                data: $0.data,
                originDeviceID: identity.stableID,
                originDeviceName: identity.displayName
            )
        }
        state.screenshot.didLoadPersistence = true
        return state
    }

    static func fixture(from arguments: [String]) -> AppFixture? {
        if arguments.contains("--app-store-screenshots") {
            return .connected
        }
        if let inline = arguments.first(where: { $0.hasPrefix("--iadb-fixture=") }) {
            return AppFixture(rawValue: String(inline.dropFirst("--iadb-fixture=".count)))
        }
        guard let flagIndex = arguments.firstIndex(of: "--iadb-fixture"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return AppFixture(rawValue: arguments[flagIndex + 1])
    }

    static func root(from arguments: [String]) -> AppFeature.Tab? {
        let rawValue: String?
        if let inline = arguments.first(where: { $0.hasPrefix("--iadb-root=") }) {
            rawValue = String(inline.dropFirst("--iadb-root=".count))
        } else if let flagIndex = arguments.firstIndex(of: "--iadb-root"),
                  arguments.indices.contains(flagIndex + 1) {
            rawValue = arguments[flagIndex + 1]
        } else {
            rawValue = nil
        }

        switch rawValue {
        case "device": return .device
        case "files": return .files
        case "apps": return .apps
        case "console": return .console
        case "screens": return .screens
        default: return nil
        }
    }

    static func state(for fixture: AppFixture) -> AppFeature.State {
        switch fixture {
        case .firstLaunch:
            return AppFeature.State()

        case .scanning:
            var state = AppFeature.State()
            state.isConnectionSetupPresented = true
            state.connection.isScanning = true
            return state

        case .pairing:
            var state = AppFeature.State()
            state.isConnectionSetupPresented = true
            state.connection.discoveredDevices = [device]
            state.connection.pairing = PairingFeature.State(
                hostInput: device.host,
                portInput: "37143",
                pairingCode: "",
                isPrefilled: true,
                serviceName: device.id
            )
            return state

        case .connecting:
            var state = initialState
            state.hasEnteredWorkspace = false
            state.isConnectionSetupPresented = true
            state.connection.connectionState = .connecting
            return state

        case .connected:
            return initialState

        case .disconnected:
            var state = initialState
            state.selectedTab = .files
            state.connection.connectionState = .disconnected
            state.connection.activeConnectionGeneration = nil
            return state

        case .reconnecting:
            var state = initialState
            state.selectedTab = .files
            state.connection.connectionState = .connecting
            return state

        case .loading:
            var state = initialState
            state.selectedTab = .files
            state.device.isLoading = true
            state.fileManager.isDirectoryLoading = true
            state.apps.isLoading = true
            state.screenshot.isLoadingPersistence = true
            return state

        case .empty:
            var state = initialState
            state.selectedTab = .files
            state.fileManager.entries = []
            state.apps.apps = []
            state.shell.history = []
            state.shell.pinnedCommands = []
            state.logcat.entries = []
            state.screenshot.screenshots = []
            return state

        case .partialData:
            var state = initialState
            state.selectedTab = .apps
            state.apps.errorMessage = String(localized: "Some package details could not be loaded. Available apps remain visible.")
            return state

        case .fileUploadProgress:
            var state = initialState
            state.selectedTab = .files
            let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            state.fileManager.activeBackgroundOperationID = operationID
            state.fileManager.activeTransferRemotePath =
                "/sdcard/Download/.iadb-upload-release-bundle.zip.tmp"
            state.operations.operations = [
                BackgroundOperation(
                    id: operationID,
                    deviceID: state.session.selectedDevice?.stableID ?? DeviceIdentity.unknownID,
                    deviceName: state.session.selectedDevice?.displayName ?? String(localized: "Unknown device"),
                    workspace: .files,
                    kind: .upload,
                    objectName: "release-bundle.zip",
                    phase: .running,
                    completedUnits: 6_291_456,
                    totalUnits: 25_165_824,
                    detail: String(localized: "Uploading to /sdcard/Download…"),
                    isCancellable: true,
                    isTransportDependent: true,
                    cleanupState: .notRequired,
                    outcome: nil,
                    retryPayload: nil,
                    startedAt: Date(timeIntervalSince1970: 1_767_268_800),
                    finishedAt: nil
                )
            ]
            return state

        case .operationProgress:
            var state = initialState
            state.selectedTab = .apps
            state.apps.isInstalling = true
            let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            state.apps.activeInstallID = operationID
            state.apps.installProgress = String(localized: "Uploading demo-build.apk — 41%")
            state.operations.operations = [
                BackgroundOperation(
                    id: operationID,
                    deviceID: state.session.selectedDevice?.stableID ?? DeviceIdentity.unknownID,
                    deviceName: state.session.selectedDevice?.displayName ?? String(localized: "Unknown device"),
                    workspace: .apps,
                    kind: .installAPK,
                    objectName: "demo-build.apk",
                    phase: .running,
                    completedUnits: 41,
                    totalUnits: 100,
                    detail: String(localized: "Uploading APK to the target device…"),
                    isCancellable: true,
                    isTransportDependent: true,
                    cleanupState: .notRequired,
                    outcome: nil,
                    retryPayload: nil,
                    startedAt: Date(timeIntervalSince1970: 1_767_268_800),
                    finishedAt: nil
                )
            ]
            return state

        case .commandProgress:
            var state = initialState
            state.selectedTab = .console
            state.shell.isExecuting = true
            state.shell.executionGeneration = 1
            state.shell.activeExecutionGeneration = 1
            state.shell.activeExecution = ShellFeature.CommandExecution(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                deviceID: state.session.selectedDevice?.stableID ?? DeviceIdentity.unknownID,
                command: "find /sdcard/Download -maxdepth 2 -type f",
                stdout: "/sdcard/Download/release-notes.txt\n/sdcard/Download/demo-build.apk\n",
                stderr: "find: /sdcard/Android/data: Permission denied\n",
                startedAt: Date(timeIntervalSince1970: 1_783_844_470),
                state: .running
            )
            return state

        case .success:
            var state = initialState
            state.selectedTab = .apps
            state.apps.statusMessage = String(localized: "Aurora Notes installed successfully.")
            return state

        case .validationError:
            var state = AppFeature.State()
            state.isConnectionSetupPresented = true
            state.connection.pairing = PairingFeature.State(
                hostInput: device.host,
                portInput: "37143",
                pairingCode: "123",
                pairingState: .error(String(localized: "Enter the six-digit pairing code shown on Android.")),
                isPrefilled: true,
                serviceName: device.id
            )
            return state

        case .connectionError:
            var state = initialState
            state.hasEnteredWorkspace = false
            state.isConnectionSetupPresented = true
            let message = String(localized: "The saved device could not be reached.")
            state.connection.connectionState = .error(message)
            state.connection.lastConnectionError = message
            state.connection.activeConnectionGeneration = nil
            return state

        case .permissionDenied:
            var state = AppFeature.State()
            state.isConnectionSetupPresented = true
            state.connection.discoveryError =
                String(localized: "Local Network access is off. Allow iADB in Settings to discover Android devices.")
            return state

        case .destructiveConfirmation:
            var state = initialState
            state.connection.pendingForgetDeviceID = pairedDevice.id
            return state

        case .partialBulkFailure:
            var state = initialState
            state.selectedTab = .files
            state.fileManager.isSelectionMode = true
            state.fileManager.selectedEntryPaths = Set(demoFiles.suffix(2).map(\.fullPath))
            state.fileManager.bulkOperation = FileManagerFeature.BulkOperationState(
                kind: .delete,
                items: demoFiles.enumerated().map { index, entry in
                    FileManagerFeature.BulkOperationState.Item(
                        entry: entry,
                        phase: index < 4
                            ? .succeeded
                            : .failed(
                                index == 4
                                    ? String(localized: "Permission denied")
                                    : String(localized: "Read-only filesystem")
                            )
                    )
                }
            )
            state.fileManager.operationSummary = String(localized: "4 succeeded, 2 failed")
            return state
        }
    }

    static let demoFiles: [FileEntry] = [
        file("Photos", permissions: "drwxrwx---", size: "", directory: true),
        file("Projects", permissions: "drwxrwx---", size: "", directory: true),
        file("demo-build.apk", permissions: "-rw-rw----", size: "24851200"),
        file("release-notes.txt", permissions: "-rw-rw----", size: "2840"),
        file("screen-capture.png", permissions: "-rw-rw----", size: "1843200"),
        file("sample-data.json", permissions: "-rw-rw----", size: "18432"),
    ]

    static var demoApps: [AppInfo] {
        [
            app("com.example.auroranotes", name: "Aurora Notes", version: "3.2.1"),
            app("com.example.canvas", name: "Canvas Demo", version: "2.4"),
            app("com.example.weather", name: "Weather Sample", version: "1.8.3"),
            app("com.example.podcast", name: "Podcast Studio", version: "5.0"),
            app("com.example.tasks", name: "Focus Tasks", version: "4.7.2"),
            app("com.android.settings", name: "Settings", version: "16", system: true),
        ]
    }

    static let shellHistory: [ShellHistoryEntry] = [
        ShellHistoryEntry(
            command: "getprop ro.build.version.release",
            output: "16",
            timestamp: Date(timeIntervalSince1970: 1_783_844_470),
            isError: false,
            exitCode: 0,
            duration: 0.08
        ),
        ShellHistoryEntry(
            command: "df -h /sdcard",
            output: "Filesystem      Size  Used Avail Use% Mounted on\n/dev/fuse       118G   42G   76G  36% /sdcard",
            timestamp: Date(timeIntervalSince1970: 1_783_844_410),
            isError: false,
            exitCode: 0,
            duration: 0.14
        ),
        ShellHistoryEntry(
            command: "wm size",
            output: "Physical size: 1080x2400",
            timestamp: Date(timeIntervalSince1970: 1_783_844_350),
            isError: false,
            exitCode: 0,
            duration: 0.06
        ),
    ]

    static let demoLogs: [LogEntry] = [
        LogEntry(timestamp: "07-12 09:41:16.204", pid: "2841", tid: "2841", level: .info, tag: "DemoActivity", message: "Dashboard ready in 184 ms"),
        LogEntry(timestamp: "07-12 09:41:16.310", pid: "2841", tid: "2910", level: .debug, tag: "SyncWorker", message: "Local project index is current"),
        LogEntry(timestamp: "07-12 09:41:17.024", pid: "2841", tid: "2932", level: .info, tag: "NetworkMonitor", message: "Connected to local Wi-Fi"),
        LogEntry(timestamp: "07-12 09:41:17.442", pid: "2841", tid: "2924", level: .warning, tag: "ImageCache", message: "Skipped one stale preview entry"),
        LogEntry(timestamp: "07-12 09:41:18.017", pid: "2841", tid: "2841", level: .info, tag: "DemoActivity", message: "Rendered 6 workspace cards"),
        LogEntry(timestamp: "07-12 09:41:18.551", pid: "2841", tid: "2932", level: .debug, tag: "RenderThread", message: "Frame completed in 8.4 ms"),
    ]

    static var demoScreenshots: [ScreenshotFeature.ScreenshotEntry] {
        let date = Date(timeIntervalSince1970: 1_783_844_470)
        return [
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: date,
                data: demoScreen(title: "Workspace", accent: UIColor(red: 0.13, green: 0.48, blue: 0.96, alpha: 1))
            ),
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: date.addingTimeInterval(-180),
                data: demoScreen(title: "Projects", accent: UIColor(red: 0.12, green: 0.72, blue: 0.58, alpha: 1))
            ),
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: date.addingTimeInterval(-360),
                data: demoScreen(title: "Activity", accent: UIColor(red: 0.52, green: 0.36, blue: 0.96, alpha: 1))
            ),
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: date.addingTimeInterval(-540),
                data: demoScreen(title: "Details", accent: UIColor(red: 0.95, green: 0.52, blue: 0.18, alpha: 1))
            ),
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: date.addingTimeInterval(-720),
                data: demoScreen(title: "Settings", accent: UIColor(red: 0.32, green: 0.58, blue: 0.72, alpha: 1))
            ),
        ]
    }

    private static func file(
        _ name: String,
        permissions: String,
        size: String,
        directory: Bool = false
    ) -> FileEntry {
        FileEntry(
            name: name,
            permissions: permissions,
            owner: "media_rw",
            group: "media_rw",
            size: size,
            date: "2026-07-12",
            time: "09:41",
            isDirectory: directory,
            isSymlink: false,
            symlinkTarget: nil,
            fullPath: "/sdcard/Download/\(name)"
        )
    }

    private static func app(
        _ package: String,
        name: String,
        version: String,
        system: Bool = false
    ) -> AppInfo {
        var result = AppInfo(packageName: package, isSystemApp: system)
        result.appName = name
        result.versionName = version
        result.targetSdk = "36"
        return result
    }

    private static func demoScreen(title: String, accent: UIColor) -> Data {
        let size = CGSize(width: 1080, height: 2400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(red: 0.035, green: 0.047, blue: 0.075, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let colors = [accent.withAlphaComponent(0.55).cgColor, UIColor.clear.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cg.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: 780, y: 340),
                    startRadius: 0,
                    endCenter: CGPoint(x: 780, y: 340),
                    endRadius: 820,
                    options: []
                )
            }

            let titleStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            title.draw(at: CGPoint(x: 72, y: 150), withAttributes: titleStyle)

            let subtitleStyle: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.68),
            ]
            "Demo Android".draw(at: CGPoint(x: 76, y: 250), withAttributes: subtitleStyle)

            for index in 0..<5 {
                let rect = CGRect(x: 72, y: 390 + CGFloat(index) * 330, width: 936, height: 260)
                UIColor.white.withAlphaComponent(0.09).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 38).fill()

                accent.withAlphaComponent(index == 0 ? 1 : 0.65).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 112, y: rect.minY + 44, width: 76, height: 76),
                    cornerRadius: 22
                ).fill()

                UIColor.white.withAlphaComponent(0.9).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 228, y: rect.minY + 55, width: 520 - CGFloat(index * 34), height: 28),
                    cornerRadius: 14
                ).fill()
                UIColor.white.withAlphaComponent(0.34).setFill()
                UIBezierPath(
                    roundedRect: CGRect(x: 228, y: rect.minY + 112, width: 690 - CGFloat(index * 42), height: 22),
                    cornerRadius: 11
                ).fill()
                UIBezierPath(
                    roundedRect: CGRect(x: 228, y: rect.minY + 158, width: 430 + CGFloat(index * 36), height: 22),
                    cornerRadius: 11
                ).fill()
            }
        }
        return image.pngData() ?? Data()
    }
}
#endif
