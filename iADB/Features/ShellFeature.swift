import Foundation
import ComposableArchitecture

@Reducer
struct ShellFeature {
    @ObservableState
    struct State: Equatable {
        var commandInput = ""
        var history: [ShellHistoryEntry] = []
        var pinnedCommands: [String] = []
        var isExecuting = false
        var didLoadPersistence = false
        var suggestions: [String] = [
            "ls -la /sdcard",
            "df -h",
            "top -n 1",
            "cat /proc/cpuinfo",
            "netstat -tlnp",
            "ps -A",
            "dumpsys meminfo",
            "getprop",
            "ip addr show",
            "logcat -d -t 50"
        ]
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case executeCommand
        case executeQuickCommand(String)
        case commandResult(command: String, Result<String, Error>)
        case clearHistory
        case loadPersistence
        case persistenceLoaded(ShellPersistenceState)
        case togglePinnedCommand(String)
        case useHistoryCommand(String)
    }

    private enum CancelID { case execution }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.shellPersistenceClient) var shellPersistenceClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.didLoadPersistence else { return .none }
                return .send(.loadPersistence)

            case .binding:
                return .none

            case .loadPersistence:
                state.didLoadPersistence = true
                return .run { send in
                    await send(.persistenceLoaded(shellPersistenceClient.load()))
                }

            case .persistenceLoaded(let persisted):
                state.history = persisted.history
                state.pinnedCommands = persisted.pinnedCommands
                return .none

            case .executeCommand:
                let command = state.commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, !state.isExecuting else { return .none }
                state.commandInput = ""
                state.isExecuting = true

                return .run { send in
                    let output = try await adbClient.shell(command)
                    await send(.commandResult(command: command, .success(output)))
                } catch: { error, send in
                    await send(.commandResult(command: command, .failure(error)))
                }

            case .executeQuickCommand(let command):
                state.commandInput = command
                return .send(.executeCommand)

            case .useHistoryCommand(let command):
                state.commandInput = command
                return .none

            case .commandResult(let command, .success(let output)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(command: command, output: output, timestamp: Date(), isError: false)
                state.history.insert(entry, at: 0)
                persist(state)
                return .none

            case .commandResult(let command, .failure(let error)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(command: command, output: error.localizedDescription, timestamp: Date(), isError: true)
                state.history.insert(entry, at: 0)
                persist(state)
                return .none

            case .clearHistory:
                state.history.removeAll()
                persist(state)
                return .none

            case .togglePinnedCommand(let command):
                if let index = state.pinnedCommands.firstIndex(of: command) {
                    state.pinnedCommands.remove(at: index)
                } else {
                    state.pinnedCommands.insert(command, at: 0)
                }
                persist(state)
                return .none
            }
        }
    }

    private func persist(_ state: State) {
        shellPersistenceClient.save(
            ShellPersistenceState(history: Array(state.history.prefix(50)), pinnedCommands: state.pinnedCommands)
        )
    }
}
