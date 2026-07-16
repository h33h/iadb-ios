import ComposableArchitecture
import Foundation

struct ShellPersistenceState: Equatable, Codable {
    var history: [ShellHistoryEntry]

    static let empty = Self(history: [])
}

struct ShellPersistenceClient: Sendable {
    var load: @Sendable () -> ShellPersistenceState
    var save: @Sendable (ShellPersistenceState) throws -> Void
}

struct ShellFileStore: Sendable {
    static let maximumBytes = 2 * 1024 * 1024

    let directoryURL: URL
    private var fileURL: URL { directoryURL.appendingPathComponent("shell-history.json") }

    func load() -> ShellPersistenceState {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(ShellPersistenceState.self, from: data) else {
            return .empty
        }
        return state
    }

    func save(_ state: ShellPersistenceState) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension ShellPersistenceClient: DependencyKey {
    static var liveValue: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iADB", isDirectory: true)
        let store = ShellFileStore(directoryURL: directory)
        return Self(load: { store.load() }, save: { try store.save($0) })
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
