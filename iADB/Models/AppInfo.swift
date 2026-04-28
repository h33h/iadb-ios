import Foundation

/// Represents an installed Android application
struct AppInfo: Identifiable, Hashable {
    var id: String { packageName }
    let packageName: String
    var appName: String?
    var versionName: String?
    var versionCode: String?
    var installDate: String?
    var lastUpdateDate: String?
    var targetSdk: String?
    var isSystemApp: Bool

    var displayName: String {
        appName ?? packageName.components(separatedBy: ".").last ?? packageName
    }

    init(packageName: String, isSystemApp: Bool = false) {
        self.packageName = packageName
        self.isSystemApp = isSystemApp
    }
}

struct AppDetail: Equatable {
    var packageName: String
    var versionName: String?
    var versionCode: String?
    var targetSdk: String?
    var firstInstallTime: String?
    var lastUpdateTime: String?
    var installerPackage: String?
    var flags: [String]
    var rawText: String

    static func parse(packageName: String, rawText: String) -> AppDetail {
        AppDetail(
            packageName: packageName,
            versionName: match("versionName=([^\\s]+)", in: rawText),
            versionCode: match("versionCode=([^\\s]+)", in: rawText),
            targetSdk: match("targetSdk=([^\\s]+)", in: rawText),
            firstInstallTime: match("firstInstallTime=([^\\n]+)", in: rawText),
            lastUpdateTime: match("lastUpdateTime=([^\\n]+)", in: rawText),
            installerPackage: match("installerPackageName=([^\\s]+)", in: rawText),
            flags: flags(in: rawText),
            rawText: rawText
        )
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flags(in text: String) -> [String] {
        guard let value = match("pkgFlags=\\[([^\\]]+)\\]", in: text) else { return [] }
        return value
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// Represents a logcat log entry
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: String
    let pid: String
    let tid: String
    let level: LogLevel
    let tag: String
    let message: String

    enum LogLevel: String, Codable {
        case verbose = "V"
        case debug = "D"
        case info = "I"
        case warning = "W"
        case error = "E"
        case fatal = "F"
        case silent = "S"
        case unknown = "?"

        var color: String {
            switch self {
            case .verbose: return "gray"
            case .debug: return "blue"
            case .info: return "green"
            case .warning: return "orange"
            case .error, .fatal: return "red"
            case .silent, .unknown: return "primary"
            }
        }
    }

    /// Parse threadtime format: "MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: MESSAGE"
    static func parse(_ line: String) -> LogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("---") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 6 else {
            return LogEntry(timestamp: "", pid: "", tid: "", level: .unknown, tag: "", message: trimmed)
        }

        let timestamp = "\(parts[0]) \(parts[1])"
        let pid = parts[2]
        let tid = parts[3]
        let levelStr = parts[4]
        let rest = parts[5]

        let level = LogLevel(rawValue: levelStr) ?? .unknown

        let colonIndex = rest.firstIndex(of: ":") ?? rest.endIndex
        let tag = String(rest[rest.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let message: String
        if colonIndex < rest.endIndex {
            message = String(rest[rest.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        } else {
            message = ""
        }

        return LogEntry(timestamp: timestamp, pid: pid, tid: tid, level: level, tag: tag, message: message)
    }
}

/// Shell command history entry
struct ShellHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let command: String
    let output: String
    let timestamp: Date
    let isError: Bool

    init(id: UUID = UUID(), command: String, output: String, timestamp: Date, isError: Bool) {
        self.id = id
        self.command = command
        self.output = output
        self.timestamp = timestamp
        self.isError = isError
    }
}
