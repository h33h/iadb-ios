import Foundation
import os

/// Local-only Instruments markers. Details are lifecycle phases and counts,
/// never device endpoints, package names, commands, paths, or log contents.
enum PerformanceSignposts {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.iadb.app"
    private static let connectionLog = OSLog(subsystem: subsystem, category: "connection-performance")
    private static let filesLog = OSLog(subsystem: subsystem, category: "files-performance")
    private static let appsLog = OSLog(subsystem: subsystem, category: "apps-performance")
    private static let shellLog = OSLog(subsystem: subsystem, category: "shell-performance")
    private static let logcatLog = OSLog(subsystem: subsystem, category: "logcat-performance")
    private static let screenshotsLog = OSLog(subsystem: subsystem, category: "screenshots-performance")

    static func connection(_ phase: String) {
        event("Connection", log: connectionLog, detail: phase)
    }

    static func directoryLoad(_ phase: String, entryCount: Int? = nil) {
        event("DirectoryLoad", log: filesLog, detail: detail(phase, count: entryCount))
    }

    static func appList(_ phase: String, packageCount: Int? = nil) {
        event("AppList", log: appsLog, detail: detail(phase, count: packageCount))
    }

    static func shellExecution(_ phase: String) {
        event("ShellExecution", log: shellLog, detail: phase)
    }

    static func logBatch(_ phase: String, lineCount: Int? = nil) {
        event("LogBatch", log: logcatLog, detail: detail(phase, count: lineCount))
    }

    static func screenshotPersistence(_ phase: String, itemCount: Int? = nil) {
        event("ScreenshotPersistence", log: screenshotsLog, detail: detail(phase, count: itemCount))
    }

    private static func detail(_ phase: String, count: Int?) -> String {
        guard let count else { return phase }
        return "\(phase) count=\(count)"
    }

    private static func event(_ name: StaticString, log: OSLog, detail: String) {
        os_signpost(.event, log: log, name: name, "%{public}@", detail as NSString)
    }
}
