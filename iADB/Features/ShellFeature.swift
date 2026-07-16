import ComposableArchitecture
import Foundation

@Reducer
struct ShellFeature {
    @ObservableState
    struct State: Equatable {
        var activeDeviceID = DeviceIdentity.unknownID
        var command = ""
        var stdout = ""
        var stderr = ""
        var exitCode: Int32?
        var isConnected = false
        var isExecuting = false
        var history: [ShellHistoryEntry] = []
        var errorMessage: String?
    }

    enum Action {
        case loadHistory
        case historyLoaded(ShellPersistenceState)
        case setDevice(String)
        case setConnected(Bool)
        case setCommand(String)
        case execute
        case event(ShellEvent)
        case failed(Error)
        case clearHistory
        case cancel
    }

    private enum CancelID { case command }
    private static let outputLimit = 2 * 1024 * 1024

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.shellPersistenceClient) var persistence
    @Dependency(\.date.now) var now

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadHistory:
                return .run { send in await send(.historyLoaded(persistence.load())) }

            case .historyLoaded(let persisted):
                state.history = persisted.history
                return .none

            case .setDevice(let id):
                state.activeDeviceID = id
                return .none

            case .setConnected(let value):
                state.isConnected = value
                return value ? .none : .send(.cancel)

            case .setCommand(let command):
                state.command = command
                return .none

            case .execute:
                let command = state.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard state.isConnected, !command.isEmpty, !state.isExecuting else { return .none }
                state.command = command
                state.stdout = ""
                state.stderr = ""
                state.exitCode = nil
                state.isExecuting = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        for try await event in try await adbClient.openShellCommand(command) {
                            await send(.event(event))
                        }
                    } catch is CancellationError {
                    } catch {
                        await send(.failed(error))
                    }
                }
                .cancellable(id: CancelID.command, cancelInFlight: true)

            case .event(.stdout(let data)):
                state.stdout = Self.appending(data, to: state.stdout)
                return .none

            case .event(.stderr(let data)):
                state.stderr = Self.appending(data, to: state.stderr)
                return .none

            case .event(.exit(let code)):
                state.exitCode = code
                state.isExecuting = false
                let entry = ShellHistoryEntry(
                    command: state.command,
                    output: state.stdout + state.stderr,
                    timestamp: now,
                    isError: code != 0,
                    originDeviceID: state.activeDeviceID,
                    stdout: state.stdout,
                    stderr: state.stderr,
                    exitCode: code,
                    wasTruncated: state.stdout.utf8.count + state.stderr.utf8.count >= Self.outputLimit
                )
                state.history.insert(entry, at: 0)
                state.history = Array(state.history.prefix(200))
                let persisted = ShellPersistenceState(history: state.history)
                return .run { _ in try persistence.save(persisted) }

            case .failed(let error):
                state.isExecuting = false
                state.errorMessage = error.localizedDescription
                return .none

            case .clearHistory:
                state.history = []
                return .run { _ in try persistence.save(.empty) }

            case .cancel:
                state.isExecuting = false
                return .cancel(id: CancelID.command)
            }
        }
    }

    private static func appending(_ data: Data, to string: String) -> String {
        let appended = string + String(decoding: data, as: UTF8.self)
        guard appended.utf8.count > outputLimit else { return appended }
        return String(appended.suffix(outputLimit))
    }
}
