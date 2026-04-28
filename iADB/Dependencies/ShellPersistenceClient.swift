import Foundation
import ComposableArchitecture

struct ShellPersistenceState: Equatable, Codable {
    var history: [ShellHistoryEntry]
    var pinnedCommands: [String]
}

struct ShellPersistenceClient: Sendable {
    var load: @Sendable () -> ShellPersistenceState
    var save: @Sendable (ShellPersistenceState) -> Void
}

extension ShellPersistenceClient: DependencyKey {
    private static let key = "shellPersistence"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let state = try? JSONDecoder().decode(ShellPersistenceState.self, from: data) else {
                    return ShellPersistenceState(history: [], pinnedCommands: [])
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
            load: unimplemented("ShellPersistenceClient.load"),
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
