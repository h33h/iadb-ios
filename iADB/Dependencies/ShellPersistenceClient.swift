import Foundation
import ComposableArchitecture

struct DeviceScopedPinnedCommand: Equatable, Codable, Identifiable {
    var id: UUID
    var command: String
    var originDeviceID: String

    init(
        id: UUID = UUID(),
        command: String,
        originDeviceID: String = DeviceIdentity.unknownID
    ) {
        self.id = id
        self.command = command
        self.originDeviceID = originDeviceID
    }
}

struct ShellPersistenceState: Equatable, Codable {
    static let currentVersion = 3

    var version: Int
    var history: [ShellHistoryEntry]
    var pinnedCommands: [DeviceScopedPinnedCommand]
    var draftsByDeviceID: [String: String]

    init(
        version: Int = currentVersion,
        history: [ShellHistoryEntry],
        scopedPinnedCommands: [DeviceScopedPinnedCommand],
        draftsByDeviceID: [String: String] = [:]
    ) {
        self.version = version
        self.history = history
        self.pinnedCommands = scopedPinnedCommands
        self.draftsByDeviceID = draftsByDeviceID
    }

    /// Source-compatible initializer for v1 fixtures and tests. Values receive
    /// explicit unknown provenance instead of being assigned to a real target.
    init(history: [ShellHistoryEntry], pinnedCommands: [String]) {
        self.init(
            history: history.map {
                ShellHistoryEntry(
                    id: $0.id,
                    command: $0.command,
                    output: $0.output,
                    timestamp: $0.timestamp,
                    isError: $0.isError,
                    originDeviceID: $0.originDeviceID,
                    stdout: $0.stdout,
                    stderr: $0.stderr,
                    exitCode: $0.exitCode,
                    duration: $0.duration,
                    wasTruncated: $0.wasTruncated,
                    usedLegacyFallback: $0.usedLegacyFallback
                )
            },
            scopedPinnedCommands: pinnedCommands.map {
                DeviceScopedPinnedCommand(command: $0)
            }
        )
    }

    static let empty = Self(history: [], scopedPinnedCommands: [], draftsByDeviceID: [:])

    static func decodeMigrating(_ data: Data) throws -> (state: Self, wasLegacy: Bool) {
        let decoder = JSONDecoder()
        if var versioned = try? decoder.decode(Self.self, from: data) {
            switch versioned.version {
            case currentVersion:
                return (versioned, false)
            case 2:
                // Shell v2 stored device provenance and drafts. Entry-level
                // streaming metadata decodes with backward-compatible defaults.
                versioned.version = currentVersion
                return (versioned, true)
            default:
                break
            }
        }

        struct Legacy: Codable {
            var history: [ShellHistoryEntry]
            var pinnedCommands: [String]
        }
        let legacy = try decoder.decode(Legacy.self, from: data)
        return (
            Self(history: legacy.history, pinnedCommands: legacy.pinnedCommands),
            true
        )
    }
}

struct ShellPersistenceClient: Sendable {
    var load: @Sendable () -> ShellPersistenceState
    var save: @Sendable (ShellPersistenceState) throws -> Void
}

struct ShellFileStore: @unchecked Sendable {
    static let maximumPersistenceBytes = 2 * 1024 * 1024

    let directoryURL: URL
    let legacyDefaults: UserDefaults?
    let legacyDefaultsKey: String

    private var fileURL: URL { directoryURL.appendingPathComponent("shell-history.json") }

    func load() -> ShellPersistenceState {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = boundedData(at: fileURL),
                  let decoded = try? ShellPersistenceState.decodeMigrating(data) else {
                // Never delete unreadable user data. A future version or a
                // support workflow may still recover it.
                return .empty
            }
            if decoded.wasLegacy {
                try? save(decoded.state)
            }
            return decoded.state
        }

        guard let data = legacyDefaults?.data(forKey: legacyDefaultsKey),
              data.count <= Self.maximumPersistenceBytes,
              let decoded = try? ShellPersistenceState.decodeMigrating(data) else {
            return .empty
        }
        do {
            try save(decoded.state)
            legacyDefaults?.removeObject(forKey: legacyDefaultsKey)
        } catch {
            // Keep UserDefaults intact until the atomic file write succeeds.
        }
        return decoded.state
    }

    func save(_ state: ShellPersistenceState) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumPersistenceBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func boundedData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= Self.maximumPersistenceBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}

extension ShellPersistenceClient: DependencyKey {
    private static let key = "shellPersistence"

    static var liveValue: Self {
        let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iADB", isDirectory: true)
        let store = ShellFileStore(
            directoryURL: directoryURL,
            legacyDefaults: .standard,
            legacyDefaultsKey: key
        )
        return Self(
            load: { store.load() },
            save: { try store.save($0) }
        )
    }

    static var previewValue: Self {
        Self(
            load: {
                ShellPersistenceState(
                    history: [ShellHistoryEntry(
                        command: "getprop ro.product.model",
                        output: "Pixel 9",
                        timestamp: Date(),
                        isError: false,
                        originDeviceID: "guid:demo-android-001"
                    )],
                    scopedPinnedCommands: [DeviceScopedPinnedCommand(
                        command: "df -h",
                        originDeviceID: "guid:demo-android-001"
                    )]
                )
            },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("ShellPersistenceClient.load", placeholder: .empty),
            save: unimplemented("ShellPersistenceClient.save")
        )
    }
}

extension DependencyValues {
    var shellPersistenceClient: ShellPersistenceClient {
        get { self[ShellPersistenceClient.self] }
        set { self[ShellPersistenceClient.self] = newValue }
    }
}
