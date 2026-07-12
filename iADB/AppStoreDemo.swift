#if DEBUG
import Foundation
import UIKit

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
        state.selectedTab = .device
        state.connection = ConnectionFeature.State(
            discoveredDevices: [device],
            pairedDevices: [pairedDevice],
            connectionState: .connected,
            lastConnectionDevice: device,
            connectionGeneration: 1,
            activeConnectionGeneration: 1
        )

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
        details.cpuAbi = "arm64-v8a"
        details.deviceName = "studio"
        state.device.details = details

        state.fileManager.currentPath = "/sdcard/Download"
        state.fileManager.pathHistory = ["/sdcard", "/sdcard/Download"]
        state.fileManager.entries = demoFiles

        state.apps.apps = demoApps
        state.apps.filter = .user

        state.shell.history = shellHistory
        state.shell.pinnedCommands = ["df -h /sdcard", "getprop ro.build.version.release"]
        state.shell.didLoadPersistence = true

        state.logcat.entries = demoLogs
        state.logcat.isRunning = true
        state.logcat.didLoadPersistence = true
        state.logcat.savedPresets = [
            LogcatPreset(name: "App lifecycle", filterText: "DemoActivity", level: nil),
            LogcatPreset(name: "Warnings", filterText: "", level: .warning),
        ]

        state.screenshot.screenshots = demoScreenshots
        state.screenshot.didLoadPersistence = true
        return state
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
            isError: false
        ),
        ShellHistoryEntry(
            command: "df -h /sdcard",
            output: "Filesystem      Size  Used Avail Use% Mounted on\n/dev/fuse       118G   42G   76G  36% /sdcard",
            timestamp: Date(timeIntervalSince1970: 1_783_844_410),
            isError: false
        ),
        ShellHistoryEntry(
            command: "wm size",
            output: "Physical size: 1080x2400",
            timestamp: Date(timeIntervalSince1970: 1_783_844_350),
            isError: false
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
