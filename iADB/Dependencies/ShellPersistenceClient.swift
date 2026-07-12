import Foundation
import ComposableArchitecture

struct ShellPersistenceState: Equatable, Codable {
    var history: [ShellHistoryEntry]
    var pinnedCommands: [String]
}

struct ShellPersistenceClient: Sendable {
    var load: @Sendable () -> ShellPersistenceState
    var save: @Sendable (ShellPersistenceState) throws -> Void
}

extension ShellPersistenceClient: DependencyKey {
    private static let key = "shellPersistence"
    private static let maximumPersistenceBytes = 2 * 1024 * 1024

    static var liveValue: Self {
        let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iADB", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("shell-history.json")

        return Self(
            load: {
                let empty = ShellPersistenceState(history: [], pinnedCommands: [])
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize,
                          size <= maximumPersistenceBytes,
                          let data = try? Data(contentsOf: fileURL),
                          let state = try? JSONDecoder().decode(ShellPersistenceState.self, from: data) else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return empty
                    }
                    return state
                }

                guard let legacyData = UserDefaults.standard.data(forKey: key),
                      legacyData.count <= maximumPersistenceBytes,
                      let state = try? JSONDecoder().decode(ShellPersistenceState.self, from: legacyData) else {
                    UserDefaults.standard.removeObject(forKey: key)
                    return empty
                }
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try? legacyData.write(to: fileURL, options: .atomic)
                UserDefaults.standard.removeObject(forKey: key)
                return state
            },
            save: { state in
                let data = try JSONEncoder().encode(state)
                guard data.count <= maximumPersistenceBytes else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                UserDefaults.standard.removeObject(forKey: key)
            }
        )
    }

    static var previewValue: Self {
        Self(
            load: {
                ShellPersistenceState(
                    history: [ShellHistoryEntry(command: "getprop ro.product.model", output: "Pixel 9", timestamp: Date(), isError: false)],
                    pinnedCommands: ["df -h", "logcat -d -t 50"]
                )
            },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented(
                "ShellPersistenceClient.load",
                placeholder: ShellPersistenceState(history: [], pinnedCommands: [])
            ),
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
