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
    var sourcePath: String?
    var dataPath: String?
    var permissions: [String]
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
            sourcePath: match("(?:codePath|sourceDir)=([^\\n]+)", in: rawText),
            dataPath: match("dataDir=([^\\n]+)", in: rawText),
            permissions: permissions(in: rawText),
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

    private static func permissions(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(?m)^\\s+([A-Za-z0-9._]+): granted=(true|false)"
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            guard result.numberOfRanges > 2,
                  let nameRange = Range(result.range(at: 1), in: text),
                  let grantedRange = Range(result.range(at: 2), in: text) else { return nil }
            let status = text[grantedRange] == "true" ? "granted" : "denied"
            return "\(text[nameRange]) — \(status)"
        }
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

    enum LogLevel: String, Codable, Hashable, CaseIterable {
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
    let originDeviceID: String
    let stdout: String
    let stderr: String
    let exitCode: Int32?
    let duration: TimeInterval?
    let wasTruncated: Bool
    let usedLegacyFallback: Bool

    init(
        id: UUID = UUID(),
        command: String,
        output: String,
        timestamp: Date,
        isError: Bool,
        originDeviceID: String = DeviceIdentity.unknownID,
        stdout: String? = nil,
        stderr: String = "",
        exitCode: Int32? = nil,
        duration: TimeInterval? = nil,
        wasTruncated: Bool = false,
        usedLegacyFallback: Bool = false
    ) {
        self.id = id
        self.command = command
        self.output = output
        self.timestamp = timestamp
        self.isError = isError
        self.originDeviceID = originDeviceID
        self.stdout = stdout ?? output
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
        self.wasTruncated = wasTruncated
        self.usedLegacyFallback = usedLegacyFallback
    }

    private enum CodingKeys: String, CodingKey {
        case id, command, output, timestamp, isError, originDeviceID
        case stdout, stderr, exitCode, duration, wasTruncated, usedLegacyFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        command = try container.decode(String.self, forKey: .command)
        output = try container.decode(String.self, forKey: .output)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isError = try container.decode(Bool.self, forKey: .isError)
        originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
            ?? DeviceIdentity.unknownID
        stdout = try container.decodeIfPresent(String.self, forKey: .stdout) ?? output
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr) ?? ""
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        wasTruncated = try container.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
        usedLegacyFallback = try container.decodeIfPresent(Bool.self, forKey: .usedLegacyFallback) ?? false
    }
}
