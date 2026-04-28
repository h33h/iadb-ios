import Foundation
import ComposableArchitecture

struct PersistedScreenshotEntry: Equatable, Codable {
    var id: UUID
    var timestamp: Date
    var fileName: String
}

struct ScreenshotPersistenceBundle: Equatable {
    var metadata: [PersistedScreenshotEntry]
    var files: [UUID: Data]
}

struct ScreenshotPersistenceClient: Sendable {
    var load: @Sendable () -> ScreenshotPersistenceBundle
    var save: @Sendable (_ metadata: [PersistedScreenshotEntry], _ files: [UUID: Data]) -> Void
    var clear: @Sendable () -> Void
}

extension ScreenshotPersistenceClient: DependencyKey {
    private static let metadataFileName = "screenshots.json"

    static var liveValue: Self {
        let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots", isDirectory: true)

        func metadataURL() -> URL {
            directoryURL.appendingPathComponent(metadataFileName)
        }

        return Self(
            load: {
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                guard let data = try? Data(contentsOf: metadataURL()),
                      let metadata = try? JSONDecoder().decode([PersistedScreenshotEntry].self, from: data) else {
                    return ScreenshotPersistenceBundle(metadata: [], files: [:])
                }

                var files: [UUID: Data] = [:]
                for entry in metadata {
                    let fileURL = directoryURL.appendingPathComponent(entry.fileName)
                    if let fileData = try? Data(contentsOf: fileURL) {
                        files[entry.id] = fileData
                    }
                }

                return ScreenshotPersistenceBundle(metadata: metadata.filter { files[$0.id] != nil }, files: files)
            },
            save: { metadata, files in
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let validFileNames = Set(metadata.map(\.fileName))
                if let existingFiles = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                    for url in existingFiles where url.lastPathComponent != metadataFileName && !validFileNames.contains(url.lastPathComponent) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                for entry in metadata {
                    guard let data = files[entry.id] else { continue }
                    let fileURL = directoryURL.appendingPathComponent(entry.fileName)
                    try? data.write(to: fileURL, options: .atomic)
                }

                if let metadataData = try? JSONEncoder().encode(metadata) {
                    try? metadataData.write(to: metadataURL(), options: .atomic)
                }
            },
            clear: {
                try? FileManager.default.removeItem(at: directoryURL)
            }
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
}
