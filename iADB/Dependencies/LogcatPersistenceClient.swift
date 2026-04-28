import Foundation
import ComposableArchitecture

struct LogcatPreset: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var filterText: String
    var level: LogEntry.LogLevel?

    init(id: UUID = UUID(), name: String, filterText: String, level: LogEntry.LogLevel?) {
        self.id = id
        self.name = name
        self.filterText = filterText
        self.level = level
    }
}

struct LogcatPersistenceState: Equatable, Codable {
    var filterText: String
    var selectedLevel: LogEntry.LogLevel?
    var presets: [LogcatPreset]
}

struct LogcatPersistenceClient: Sendable {
    var load: @Sendable () -> LogcatPersistenceState
    var save: @Sendable (LogcatPersistenceState) -> Void
}

extension LogcatPersistenceClient: DependencyKey {
    private static let key = "logcatPersistence"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let state = try? JSONDecoder().decode(LogcatPersistenceState.self, from: data) else {
                    return LogcatPersistenceState(filterText: "", selectedLevel: nil, presets: [])
                }
                return state
            },
            save: { state in
                guard let data = try? JSONEncoder().encode(state) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        )
    }

    static var previewValue: Self {
        Self(
            load: {
                LogcatPersistenceState(
                    filterText: "ActivityManager",
                    selectedLevel: .error,
                    presets: [LogcatPreset(name: "Errors", filterText: "", level: .error)]
                )
            },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("LogcatPersistenceClient.load"),
            save: unimplemented("LogcatPersistenceClient.save")
        )
    }
}

extension DependencyValues {
    var logcatPersistenceClient: LogcatPersistenceClient {
        get { self[LogcatPersistenceClient.self] }
        set { self[LogcatPersistenceClient.self] = newValue }
    }
}
