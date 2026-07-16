import Foundation

/// Represents an installed Android application
struct AppInfo: Identifiable, Hashable {
    var id: String { packageName }
    let packageName: String

}

/// Represents a logcat log entry
struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: String
    let pid: String
    let tid: String
    let level: LogLevel
    let tag: String
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: String,
        pid: String,
        tid: String,
        level: LogLevel,
        tag: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
        self.message = message
    }

    enum LogLevel: String, Codable, Hashable, CaseIterable {
        case verbose = "V"
        case debug = "D"
        case info = "I"
        case warning = "W"
        case error = "E"
        case fatal = "F"
        case silent = "S"
        case unknown = "?"

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
        wasTruncated: Bool = false
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
    }
}
