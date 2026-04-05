import Foundation
import ComposableArchitecture

@Reducer
struct ShellFeature {
    @ObservableState
    struct State: Equatable {
        var commandInput = ""
        var history: [ShellHistoryEntry] = []
        var isExecuting = false
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
        case executeCommand
        case executeQuickCommand(String)
        case commandResult(command: String, Result<String, Error>)
        case clearHistory
    }

    private enum CancelID { case execution }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
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

            case .commandResult(let command, .success(let output)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(command: command, output: output, timestamp: Date(), isError: false)
                state.history.insert(entry, at: 0)
                return .none

            case .commandResult(let command, .failure(let error)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(command: command, output: error.localizedDescription, timestamp: Date(), isError: true)
                state.history.insert(entry, at: 0)
                return .none

            case .clearHistory:
                state.history.removeAll()
                return .none
            }
        }
    }
}
