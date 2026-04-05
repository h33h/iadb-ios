import Foundation
import XCTest
@testable import iADB

final class AppInfoTests: XCTestCase {

    // MARK: - AppInfo

    func testAppInfoInit() {
        let app = AppInfo(packageName: "com.example.app")
        XCTAssertEqual(app.packageName, "com.example.app")
        XCTAssertFalse(app.isSystemApp)
        XCTAssertNil(app.appName)
        XCTAssertNil(app.versionName)
    }

    func testAppInfoSystemApp() {
        let app = AppInfo(packageName: "com.android.settings", isSystemApp: true)
        XCTAssertTrue(app.isSystemApp)
    }

    func testDisplayNameWithAppName() {
        var app = AppInfo(packageName: "com.example.app")
        app.appName = "My App"
        XCTAssertEqual(app.displayName, "My App")
    }

    func testDisplayNameFallbackToLastComponent() {
        let app = AppInfo(packageName: "com.example.calculator")
        XCTAssertEqual(app.displayName, "calculator")
    }

    func testDisplayNameSingleComponent() {
        let app = AppInfo(packageName: "myapp")
        XCTAssertEqual(app.displayName, "myapp")
    }

    func testAppInfoHashable() {
        let a1 = AppInfo(packageName: "com.a")
        let a2 = AppInfo(packageName: "com.b")
        let set: Set<AppInfo> = [a1, a2]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - LogEntry

    func testLogEntryParseStandard() {
        let line = "01-15 10:30:45.123  1234  5678 D MyTag: This is a debug message"
        let entry = LogEntry.parse(line)

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.timestamp, "01-15 10:30:45.123")
        XCTAssertEqual(entry?.pid, "1234")
        XCTAssertEqual(entry?.tid, "5678")
        XCTAssertEqual(entry?.level, .debug)
        XCTAssertEqual(entry?.tag, "MyTag")
        XCTAssertEqual(entry?.message, "This is a debug message")
    }

    func testLogEntryParseAllLevels() {
        let levels: [(String, LogEntry.LogLevel)] = [
            ("V", .verbose), ("D", .debug), ("I", .info),
            ("W", .warning), ("E", .error), ("F", .fatal),
            ("S", .silent)
        ]

        for (str, expected) in levels {
            let line = "01-01 00:00:00.000  1  1 \(str) Tag: msg"
            let entry = LogEntry.parse(line)
            XCTAssertEqual(entry?.level, expected, "Level \(str) should parse to \(expected)")
        }
    }

    func testLogEntryParseUnknownLevel() {
        let line = "01-01 00:00:00.000  1  1 X Tag: msg"
        let entry = LogEntry.parse(line)
        XCTAssertEqual(entry?.level, .unknown)
    }

    func testLogEntryParseEmpty() {
        XCTAssertNil(LogEntry.parse(""))
        XCTAssertNil(LogEntry.parse("   "))
    }

    func testLogEntryParseDivider() {
        XCTAssertNil(LogEntry.parse("--------- beginning of main"))
    }

    func testLogEntryParseShortLine() {
        // Lines with fewer than 6 parts should still create an entry with the raw text
        let line = "some random output"
        let entry = LogEntry.parse(line)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.level, .unknown)
        XCTAssertEqual(entry?.message, "some random output")
    }

    func testLogEntryParseMessageWithColons() {
        let line = "01-01 00:00:00.000  1  1 I Tag: key:value:more"
        let entry = LogEntry.parse(line)
        XCTAssertEqual(entry?.tag, "Tag")
        XCTAssertEqual(entry?.message, "key:value:more")
    }

    // MARK: - LogLevel Color

    func testLogLevelColors() {
        XCTAssertEqual(LogEntry.LogLevel.verbose.color, "gray")
        XCTAssertEqual(LogEntry.LogLevel.debug.color, "blue")
        XCTAssertEqual(LogEntry.LogLevel.info.color, "green")
        XCTAssertEqual(LogEntry.LogLevel.warning.color, "orange")
        XCTAssertEqual(LogEntry.LogLevel.error.color, "red")
        XCTAssertEqual(LogEntry.LogLevel.fatal.color, "red")
        XCTAssertEqual(LogEntry.LogLevel.silent.color, "primary")
        XCTAssertEqual(LogEntry.LogLevel.unknown.color, "primary")
    }

    func testLogLevelRawValues() {
        XCTAssertEqual(LogEntry.LogLevel.verbose.rawValue, "V")
        XCTAssertEqual(LogEntry.LogLevel.debug.rawValue, "D")
        XCTAssertEqual(LogEntry.LogLevel.info.rawValue, "I")
        XCTAssertEqual(LogEntry.LogLevel.warning.rawValue, "W")
        XCTAssertEqual(LogEntry.LogLevel.error.rawValue, "E")
        XCTAssertEqual(LogEntry.LogLevel.fatal.rawValue, "F")
        XCTAssertEqual(LogEntry.LogLevel.silent.rawValue, "S")
        XCTAssertEqual(LogEntry.LogLevel.unknown.rawValue, "?")
    }

    // MARK: - ShellHistoryEntry

    func testShellHistoryEntry() {
        let entry = ShellHistoryEntry(command: "ls", output: "file.txt", timestamp: Date(), isError: false)
        XCTAssertEqual(entry.command, "ls")
        XCTAssertEqual(entry.output, "file.txt")
        XCTAssertFalse(entry.isError)
        XCTAssertNotNil(entry.id)
    }

    func testShellHistoryEntryError() {
        let entry = ShellHistoryEntry(command: "bad_cmd", output: "not found", timestamp: Date(), isError: true)
        XCTAssertTrue(entry.isError)
    }

    func testShellHistoryEntryUniqueIds() {
        let e1 = ShellHistoryEntry(command: "a", output: "", timestamp: Date(), isError: false)
        let e2 = ShellHistoryEntry(command: "a", output: "", timestamp: Date(), isError: false)
        XCTAssertNotEqual(e1.id, e2.id)
    }
}
