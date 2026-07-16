import ComposableArchitecture
import Foundation

let screenshotStorageByteLimit = 100 * 1024 * 1024

struct PersistedScreenshotEntry: Equatable, Codable {
    var id: UUID
    var timestamp: Date
    var fileName: String
    var originDeviceID: String
    var originDeviceName: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
}

struct ScreenshotPersistenceBundle: Equatable {
    var metadata: [PersistedScreenshotEntry]
    var files: [UUID: Data]
}

struct ScreenshotPersistenceClient: Sendable {
    var load: @Sendable () throws -> ScreenshotPersistenceBundle
    var save: @Sendable (_ metadata: [PersistedScreenshotEntry], _ files: [UUID: Data]) throws -> Void
    var clear: @Sendable () throws -> Void
}

struct ScreenshotFileStore: Sendable {
    private static let metadataFileName = "screenshots.json"
    let directoryURL: URL

    private var metadataURL: URL { directoryURL.appendingPathComponent(Self.metadataFileName) }

    func load() throws -> ScreenshotPersistenceBundle {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return ScreenshotPersistenceBundle(metadata: [], files: [:])
        }
        let metadata = try JSONDecoder().decode(
            [PersistedScreenshotEntry].self,
            from: Data(contentsOf: metadataURL)
        )
        try Self.validateMetadata(metadata)

        var files: [UUID: Data] = [:]
        var totalBytes = 0
        for entry in metadata {
            let data = try Data(contentsOf: directoryURL.appendingPathComponent(entry.fileName))
            guard data.count == entry.byteCount,
                  data.count <= screenshotStorageByteLimit - totalBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            files[entry.id] = data
            totalBytes += data.count
        }
        return ScreenshotPersistenceBundle(metadata: metadata, files: files)
    }

    func save(_ metadata: [PersistedScreenshotEntry], _ files: [UUID: Data]) throws {
        try Self.validateMetadata(metadata)
        let totalBytes = metadata.reduce(0) { $0 + $1.byteCount }
        guard totalBytes <= screenshotStorageByteLimit,
              Set(files.keys) == Set(metadata.map(\.id)) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let parent = directoryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("\(directoryURL.lastPathComponent)-\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        for entry in metadata {
            guard let data = files[entry.id], data.count == entry.byteCount else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: staging.appendingPathComponent(entry.fileName), options: .atomic)
        }
        try JSONEncoder().encode(metadata).write(
            to: staging.appendingPathComponent(Self.metadataFileName),
            options: .atomic
        )

        if FileManager.default.fileExists(atPath: directoryURL.path) {
            _ = try FileManager.default.replaceItemAt(directoryURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: directoryURL)
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private static func validateMetadata(_ metadata: [PersistedScreenshotEntry]) throws {
        guard Set(metadata.map(\.id)).count == metadata.count,
              Set(metadata.map(\.fileName)).count == metadata.count,
              metadata.allSatisfy({ entry in
                  !entry.fileName.isEmpty &&
                  entry.fileName == (entry.fileName as NSString).lastPathComponent &&
                  entry.byteCount >= 0
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

extension ScreenshotPersistenceClient: DependencyKey {
    static var liveValue: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iADB/Screenshots", isDirectory: true)
        let store = ScreenshotFileStore(directoryURL: directory)
        return Self(
            load: { try store.load() },
            save: { try store.save($0, $1) },
            clear: { try store.clear() }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("ScreenshotPersistenceClient.load"),
            save: unimplemented("ScreenshotPersistenceClient.save"),
            clear: unimplemented("ScreenshotPersistenceClient.clear")
        )
    }
}

extension DependencyValues {
    var screenshotPersistenceClient: ScreenshotPersistenceClient {
        get { self[ScreenshotPersistenceClient.self] }
        set { self[ScreenshotPersistenceClient.self] = newValue }
    }
}
