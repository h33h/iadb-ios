import Foundation
import ComposableArchitecture

let screenshotStorageByteLimit = 100 * 1024 * 1024

enum ScreenshotRetentionPolicy: String, CaseIterable, Codable, Equatable, Identifiable {
    case unlimited
    case compact
    case standard
    case extended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimited: String(localized: "No Limit")
        case .compact: String(localized: "Compact")
        case .standard: String(localized: "Standard")
        case .extended: String(localized: "Extended")
        }
    }

    var countLimit: Int {
        switch self {
        case .unlimited: Int.max
        case .compact: 25
        case .standard, .extended: 50
        }
    }

    var byteLimit: Int {
        switch self {
        case .unlimited: Int.max
        case .compact: 25 * 1024 * 1024
        case .standard: 50 * 1024 * 1024
        case .extended: screenshotStorageByteLimit
        }
    }

    var detail: String {
        self == .unlimited
            ? String(localized: "No automatic cleanup")
            : String(localized: "\(countLimit) captures · \(byteLimit / 1024 / 1024) MB")
    }
}

struct ScreenshotRetentionClient: Sendable {
    var load: @Sendable () -> ScreenshotRetentionPolicy
    var save: @Sendable (ScreenshotRetentionPolicy) -> Void
}

extension ScreenshotRetentionClient: DependencyKey {
    private static let key = "screenshotRetentionPolicy"

    static var liveValue: Self {
        Self(
            load: {
                // Legacy policies remain decodable, but current builds no longer remove captures
                // automatically. The stored value is left intact for rollback compatibility.
                .unlimited
            },
            save: { policy in UserDefaults.standard.set(policy.rawValue, forKey: key) }
        )
    }

    static var previewValue: Self { Self(load: { .unlimited }, save: { _ in }) }
    static var testValue: Self { Self(load: { .unlimited }, save: { _ in }) }
}

struct PersistedScreenshotEntry: Equatable, Codable {
    var id: UUID
    var timestamp: Date
    var fileName: String
    var originDeviceID: String
    var originDeviceName: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var note: String?

    init(
        id: UUID,
        timestamp: Date,
        fileName: String,
        originDeviceID: String = DeviceIdentity.unknownID,
        originDeviceName: String? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        byteCount: Int = 0,
        note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.originDeviceID = originDeviceID
        self.originDeviceName = originDeviceName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, originDeviceID, originDeviceName
        case pixelWidth, pixelHeight, byteCount, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        fileName = try container.decode(String.self, forKey: .fileName)
        originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
            ?? DeviceIdentity.unknownID
        originDeviceName = try container.decodeIfPresent(String.self, forKey: .originDeviceName)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

struct ScreenshotMetadataEnvelope: Equatable, Codable {
    static let currentVersion = 2

    var version: Int
    var entries: [PersistedScreenshotEntry]

    init(version: Int = currentVersion, entries: [PersistedScreenshotEntry]) {
        self.version = version
        self.entries = entries
    }
}

struct ScreenshotPersistenceBundle: Equatable {
    var metadata: [PersistedScreenshotEntry]
    var files: [UUID: Data]
    var warnings: [String] = []
    var needsMigration = false
}

struct ScreenshotPersistenceClient: Sendable {
    var load: @Sendable () throws -> ScreenshotPersistenceBundle
    var save: @Sendable (_ metadata: [PersistedScreenshotEntry], _ files: [UUID: Data]) throws -> Void
    var clear: @Sendable () throws -> Void
}

/// A generation-based store. A complete generation is written before the small
/// current-generation pointer is atomically committed, so a failed save never
/// deletes or mutates the last readable screenshot set.
struct ScreenshotFileStore {
    private struct CurrentGeneration: Codable {
        var directoryName: String
    }

    private static let metadataFileName = "screenshots.json"
    private static let currentFileName = "current.json"
    private static let generationPrefix = "generation-"
    private static let stagingSuffix = ".tmp"

    let directoryURL: URL

    func load() throws -> ScreenshotPersistenceBundle {
        sweepDeletedStores()
        let currentURL = directoryURL.appendingPathComponent(Self.currentFileName)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            let pointerData = try Data(contentsOf: currentURL)
            let pointer = try JSONDecoder().decode(CurrentGeneration.self, from: pointerData)
            guard Self.isValidGenerationName(pointer.directoryName) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try loadGeneration(at: directoryURL.appendingPathComponent(pointer.directoryName, isDirectory: true))
        }

        // Read the pre-generation layout so existing installs migrate without
        // losing screenshots. The next successful save commits a generation.
        let legacyMetadataURL = directoryURL.appendingPathComponent(Self.metadataFileName)
        guard FileManager.default.fileExists(atPath: legacyMetadataURL.path) else {
            return ScreenshotPersistenceBundle(metadata: [], files: [:])
        }
        return try loadBundle(metadataURL: legacyMetadataURL, filesDirectoryURL: directoryURL)
    }

    func save(
        _ metadata: [PersistedScreenshotEntry],
        _ files: [UUID: Data],
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        sweepDeletedStores()
        try Self.validate(metadata: metadata, files: files)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let generationID = UUID().uuidString
        let finalName = Self.generationPrefix + generationID
        let stagingName = finalName + Self.stagingSuffix
        let stagingURL = directoryURL.appendingPathComponent(stagingName, isDirectory: true)
        let finalURL = directoryURL.appendingPathComponent(finalName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)

        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingURL)
                try? FileManager.default.removeItem(at: finalURL)
            }
        }

        for entry in metadata {
            guard let data = files[entry.id] else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: stagingURL.appendingPathComponent(entry.fileName), options: .atomic)
        }
        let metadataData = try JSONEncoder().encode(ScreenshotMetadataEnvelope(entries: metadata))
        try metadataData.write(
            to: stagingURL.appendingPathComponent(Self.metadataFileName),
            options: .atomic
        )

        // A rename makes this immutable, complete generation visible as one unit.
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        try beforeCommit?()

        let pointerData = try JSONEncoder().encode(CurrentGeneration(directoryName: finalName))
        try pointerData.write(
            to: directoryURL.appendingPathComponent(Self.currentFileName),
            options: .atomic
        )
        committed = true

        // Cleanup happens only after commit and is best effort. A cleanup error
        // cannot turn a successfully committed save into an apparent rollback.
        cleanupKeeping(generationName: finalName)
    }

    func clear() throws {
        sweepDeletedStores()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let tombstoneURL = directoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(directoryURL.lastPathComponent).deleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: directoryURL, to: tombstoneURL)
        try? FileManager.default.removeItem(at: tombstoneURL)
        sweepDeletedStores()
    }

    /// `clear()` first renames the active store so it becomes empty
    /// atomically. Reclaim tombstones left behind by transient remove errors on
    /// every subsequent store operation.
    private func sweepDeletedStores() {
        let fileManager = FileManager.default
        let parentURL = directoryURL.deletingLastPathComponent()
        let prefix = directoryURL.lastPathComponent + ".deleted-"
        guard let children = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    private func loadGeneration(at generationURL: URL) throws -> ScreenshotPersistenceBundle {
        let metadataURL = generationURL.appendingPathComponent(Self.metadataFileName)
        return try loadBundle(metadataURL: metadataURL, filesDirectoryURL: generationURL)
    }

    private func loadBundle(metadataURL: URL, filesDirectoryURL: URL) throws -> ScreenshotPersistenceBundle {
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        let metadata: [PersistedScreenshotEntry]
        let usesLegacySchema: Bool
        if let envelope = try? decoder.decode(ScreenshotMetadataEnvelope.self, from: metadataData),
           envelope.version == ScreenshotMetadataEnvelope.currentVersion {
            metadata = envelope.entries
            usesLegacySchema = false
        } else {
            metadata = try decoder.decode([PersistedScreenshotEntry].self, from: metadataData)
            usesLegacySchema = true
        }

        var files: [UUID: Data] = [:]
        var warnings: [String] = []
        var retainedBytes = 0
        var seenIDs = Set<UUID>()
        var seenFileNames = Set<String>()
        var acceptedMetadata: [PersistedScreenshotEntry] = []

        for entry in metadata {
            guard seenIDs.insert(entry.id).inserted,
                  seenFileNames.insert(entry.fileName).inserted,
                  Self.isSafeFileName(entry.fileName) else {
                warnings.append(entry.fileName)
                continue
            }
            let fileURL = filesDirectoryURL.appendingPathComponent(entry.fileName)
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                guard data.count <= screenshotStorageByteLimit - retainedBytes else {
                    warnings.append(entry.fileName)
                    continue
                }
                files[entry.id] = data
                acceptedMetadata.append(entry)
                retainedBytes += data.count
            } catch {
                warnings.append(entry.fileName)
            }
        }

        return ScreenshotPersistenceBundle(
            metadata: acceptedMetadata,
            files: files,
            warnings: warnings,
            needsMigration: usesLegacySchema || acceptedMetadata.contains {
                $0.pixelWidth <= 0 || $0.pixelHeight <= 0 || $0.byteCount <= 0
            }
        )
    }

    private func cleanupKeeping(generationName: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for url in contents {
            let name = url.lastPathComponent
            if name == Self.currentFileName || name == generationName { continue }
            if name == Self.metadataFileName || name.hasPrefix(Self.generationPrefix) || Self.isSafeFileName(name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func validate(
        metadata: [PersistedScreenshotEntry],
        files: [UUID: Data]
    ) throws {
        guard Set(metadata.map(\.id)).count == metadata.count,
              Set(metadata.map(\.fileName)).count == metadata.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        var totalBytes = 0
        for entry in metadata {
            guard isSafeFileName(entry.fileName), let data = files[entry.id] else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            guard data.count <= screenshotStorageByteLimit - totalBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            totalBytes += data.count
        }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty &&
            name != "." &&
            name != ".." &&
            !name.contains("\0") &&
            (name as NSString).lastPathComponent == name
    }

    private static func isValidGenerationName(_ name: String) -> Bool {
        name.hasPrefix(generationPrefix) &&
            !name.hasSuffix(stagingSuffix) &&
            isSafeFileName(name)
    }
}

extension ScreenshotPersistenceClient: DependencyKey {
    static var liveValue: Self {
        let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots", isDirectory: true)
        let store = ScreenshotFileStore(directoryURL: directoryURL)

        return Self(
            load: { try store.load() },
            save: { metadata, files in try store.save(metadata, files) },
            clear: { try store.clear() }
        )
    }

    static var previewValue: Self {
        Self(
            load: { ScreenshotPersistenceBundle(metadata: [], files: [:]) },
            save: { _, _ in },
            clear: {}
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

    var screenshotRetentionClient: ScreenshotRetentionClient {
        get { self[ScreenshotRetentionClient.self] }
        set { self[ScreenshotRetentionClient.self] = newValue }
    }
}
