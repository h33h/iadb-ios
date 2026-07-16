import Foundation
import XCTest
@testable import iADB

final class PersistenceTests: XCTestCase {
    func testShellStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellFileStore(directoryURL: directory)
        let expected = ShellPersistenceState(history: [
            ShellHistoryEntry(command: "id", output: "uid=2000", timestamp: .distantPast, isError: false)
        ])

        try store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testScreenshotStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotFileStore(directoryURL: directory)
        let id = UUID()
        let data = Data([1, 2, 3])
        let metadata = [PersistedScreenshotEntry(
            id: id,
            timestamp: .distantPast,
            fileName: "\(id).png",
            originDeviceID: "device",
            originDeviceName: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: data.count
        )]

        try store.save(metadata, [id: data])
        let loaded = try store.load()

        XCTAssertEqual(loaded.metadata, metadata)
        XCTAssertEqual(loaded.files, [id: data])
    }
}
