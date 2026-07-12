import Foundation
import ComposableArchitecture

/// Serializes shell persistence and rejects a stale snapshot even when effect
/// tasks reach the writer out of reducer order.
actor ShellPersistenceWriter {
    private var latestGeneration = 0

    func save(
        generation: Int,
        state: ShellPersistenceState,
        client: ShellPersistenceClient
    ) throws {
        guard generation > latestGeneration else { return }
        latestGeneration = generation
        try client.save(state)
    }
}

@Reducer
struct ShellFeature {
    static let maximumCommandBytes = 16 * 1024
    static let maximumEntryOutputBytes = 128 * 1024
    static let maximumHistoryBytes = 1024 * 1024
    static let maximumPinnedCommandBytes = 256 * 1024
    static let maximumPinnedCommandCount = 50

    @ObservableState
    struct State: Equatable {
        var commandInput = ""
        var history: [ShellHistoryEntry] = []
        var pinnedCommands: [String] = []
        var isExecuting = false
        var didLoadPersistence = false
        var persistenceGeneration = 0
        var errorMessage: String?
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
        case cancelExecution
        case cancelAll
        case executeQuickCommand(String)
        case commandResult(command: String, Result<String, Error>)
        case clearHistory
        case loadPersistence
        case persistenceLoaded(ShellPersistenceState)
        case togglePinnedCommand(String)
        case useHistoryCommand(String)
        case persistenceFailed(generation: Int, String)
        case dismissError
    }

    private enum CancelID { case execution }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.shellPersistenceClient) var shellPersistenceClient
    private let persistenceWriter = ShellPersistenceWriter()

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
                state.history = Self.retainedHistory(persisted.history)
                state.pinnedCommands = Self.retainedPinnedCommands(persisted.pinnedCommands)
                return .none

            case .executeCommand:
                let command = state.commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, !state.isExecuting else { return .none }
                state.commandInput = ""
                guard command.utf8.count <= Self.maximumCommandBytes else {
                    state.history.insert(
                        ShellHistoryEntry(
                            command: String(command.prefix(256)) + "…",
                            output: "Command exceeds iADB's 16 KiB safety limit.",
                            timestamp: Date(),
                            isError: true
                        ),
                        at: 0
                    )
                    state.history = Self.retainedHistory(state.history)
                    return persist(&state)
                }
                state.isExecuting = true

                return .run { send in
                    let output = try await adbClient.shell(command)
                    await send(.commandResult(command: command, .success(output)))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.commandResult(command: command, .failure(error)))
                }
                .cancellable(id: CancelID.execution, cancelInFlight: true)

            case .cancelExecution:
                guard state.isExecuting else { return .none }
                state.isExecuting = false
                return .cancel(id: CancelID.execution)

            case .cancelAll:
                state.isExecuting = false
                return .cancel(id: CancelID.execution)

            case .executeQuickCommand(let command):
                state.commandInput = command
                return .send(.executeCommand)

            case .useHistoryCommand(let command):
                state.commandInput = command
                return .none

            case .commandResult(let command, .success(let output)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(
                    command: command,
                    output: Self.truncatedOutput(output),
                    timestamp: Date(),
                    isError: false
                )
                state.history.insert(entry, at: 0)
                state.history = Self.retainedHistory(state.history)
                return persist(&state)

            case .commandResult(let command, .failure(let error)):
                state.isExecuting = false
                let entry = ShellHistoryEntry(
                    command: command,
                    output: Self.truncatedOutput(error.localizedDescription),
                    timestamp: Date(),
                    isError: true
                )
                state.history.insert(entry, at: 0)
                state.history = Self.retainedHistory(state.history)
                return persist(&state)

            case .clearHistory:
                state.history.removeAll()
                return persist(&state)

            case .togglePinnedCommand(let command):
                if let index = state.pinnedCommands.firstIndex(of: command) {
                    state.pinnedCommands.remove(at: index)
                } else {
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumCommandBytes else {
                        state.errorMessage = "This command is too large to pin."
                        return .none
                    }
                    state.pinnedCommands = Self.retainedPinnedCommands([trimmed] + state.pinnedCommands)
                }
                return persist(&state)

            case .persistenceFailed(let generation, let message):
                guard generation == state.persistenceGeneration else { return .none }
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }

    private func persist(_ state: inout State) -> Effect<Action> {
        state.persistenceGeneration &+= 1
        let generation = state.persistenceGeneration
        let persisted = ShellPersistenceState(
            history: Self.retainedHistory(state.history),
            pinnedCommands: Self.retainedPinnedCommands(state.pinnedCommands)
        )
        let persistenceWriter = persistenceWriter
        return .run { _ in
            try await persistenceWriter.save(
                generation: generation,
                state: persisted,
                client: shellPersistenceClient
            )
        } catch: { error, send in
            await send(.persistenceFailed(
                generation: generation,
                "Could not save shell history: \(error.localizedDescription)"
            ))
        }
    }

    static func truncatedOutput(_ output: String, byteLimit: Int = maximumEntryOutputBytes) -> String {
        guard output.utf8.count > byteLimit else { return output }
        let prefix = output.utf8.prefix(max(0, byteLimit))
        return String(decoding: prefix, as: UTF8.self) + "\n… Output truncated by iADB …"
    }

    static func retainedHistory(
        _ history: [ShellHistoryEntry],
        byteLimit: Int = maximumHistoryBytes
    ) -> [ShellHistoryEntry] {
        var retained: [ShellHistoryEntry] = []
        var retainedBytes = 0
        for entry in history.prefix(50) {
            let entryBytes = entry.command.utf8.count + entry.output.utf8.count
            guard entryBytes <= byteLimit - retainedBytes else { break }
            retained.append(entry)
            retainedBytes += entryBytes
        }
        return retained
    }

    static func retainedPinnedCommands(
        _ commands: [String],
        countLimit: Int = maximumPinnedCommandCount,
        byteLimit: Int = maximumPinnedCommandBytes
    ) -> [String] {
        var retained: [String] = []
        var seen = Set<String>()
        var retainedBytes = 0
        for rawCommand in commands {
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = command.utf8.count
            guard !command.isEmpty,
                  bytes <= maximumCommandBytes,
                  seen.insert(command).inserted,
                  retained.count < max(0, countLimit),
                  bytes <= byteLimit - retainedBytes else { continue }
            retained.append(command)
            retainedBytes += bytes
        }
        return retained
    }
}
