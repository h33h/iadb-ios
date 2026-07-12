import Foundation
import Testing
@testable import iADB

struct ScreenshotPersistenceClientTests {
    @Test
    func failedSaveKeepsLastCommittedGenerationReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-screenshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotFileStore(directoryURL: root)

        let oldID = UUID()
        let oldMetadata = [PersistedScreenshotEntry(
            id: oldID,
            timestamp: Date(timeIntervalSince1970: 1),
            fileName: "\(oldID.uuidString).png"
        )]
        let oldData = Data("old".utf8)
        try store.save(oldMetadata, [oldID: oldData])

        struct InjectedFailure: Error {}
        let newID = UUID()
        let newMetadata = [PersistedScreenshotEntry(
            id: newID,
            timestamp: Date(timeIntervalSince1970: 2),
            fileName: "\(newID.uuidString).png"
        )]
        #expect(throws: InjectedFailure.self) {
            try store.save(newMetadata, [newID: Data("new".utf8)]) {
                throw InjectedFailure()
            }
        }

        let loaded = try store.load()
        #expect(loaded.metadata == oldMetadata)
        #expect(loaded.files == [oldID: oldData])
    }

    @Test
    func clearMakesStoreImmediatelyReadAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-screenshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotFileStore(directoryURL: root)
        let id = UUID()
        let metadata = [PersistedScreenshotEntry(
            id: id,
            timestamp: Date(),
            fileName: "\(id.uuidString).png"
        )]
        try store.save(metadata, [id: Data([1, 2, 3])])

        try store.clear()

        #expect(try store.load() == ScreenshotPersistenceBundle(metadata: [], files: [:]))
    }

    @Test
    func unsafePersistedFileNameIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-screenshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotFileStore(directoryURL: root)
        let id = UUID()
        let metadata = [PersistedScreenshotEntry(
            id: id,
            timestamp: Date(),
            fileName: "../outside.png"
        )]

        #expect(throws: (any Error).self) {
            try store.save(metadata, [id: Data([1])])
        }
    }

    @Test
    func loadSweepsAValidClearTombstoneButLeavesUnrelatedDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-screenshot-store-\(UUID().uuidString)", isDirectory: true)
        let parent = root.deletingLastPathComponent()
        let tombstone = parent.appendingPathComponent(
            "\(root.lastPathComponent).deleted-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelated = parent.appendingPathComponent(
            "\(root.lastPathComponent).deleted-not-a-uuid",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: tombstone)
            try? FileManager.default.removeItem(at: unrelated)
        }
        try FileManager.default.createDirectory(at: tombstone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        _ = try ScreenshotFileStore(directoryURL: root).load()

        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func legacyLoadRejectsDuplicateFileNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-screenshot-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstID = UUID()
        let secondID = UUID()
        let sharedFileName = "shared.png"
        let metadata = [
            PersistedScreenshotEntry(id: firstID, timestamp: Date(timeIntervalSince1970: 1), fileName: sharedFileName),
            PersistedScreenshotEntry(id: secondID, timestamp: Date(timeIntervalSince1970: 2), fileName: sharedFileName)
        ]
        try JSONEncoder().encode(metadata).write(
            to: root.appendingPathComponent("screenshots.json"),
            options: .atomic
        )
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(sharedFileName))

        let loaded = try ScreenshotFileStore(directoryURL: root).load()

        #expect(loaded.metadata == [metadata[0]])
        #expect(loaded.files == [firstID: Data([1, 2, 3])])
        #expect(loaded.warnings == [sharedFileName])
    }
}
