import XCTest
@testable import iADB

final class AppInfoTests: XCTestCase {
    func testLogcatThreadtimeParser() throws {
        let entry = try XCTUnwrap(LogEntry.parse("08-16 12:30:15.123  123  456 E Network: failed"))
        XCTAssertEqual(entry.timestamp, "08-16 12:30:15.123")
        XCTAssertEqual(entry.pid, "123")
        XCTAssertEqual(entry.tid, "456")
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.tag, "Network")
        XCTAssertEqual(entry.message, "failed")
    }
}
