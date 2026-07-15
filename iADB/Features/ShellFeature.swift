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

    static func accessibilityAnnouncement(
        wasExecuting: Bool,
        isExecuting: Bool,
        execution: CommandExecution?
    ) -> String? {
        if !wasExecuting, isExecuting {
            return String(localized: "Shell command started")
        }
        guard wasExecuting, !isExecuting, let execution else { return nil }
        if let exitCode = execution.exitCode {
            return String(localized: "Shell command completed with exit code \(exitCode)")
        }
        switch execution.state {
        case .failed:
            return String(localized: "Shell command failed without an exit code")
        case .cancelled:
            return String(localized: "Shell command stopped")
        case .running, .succeeded:
            return String(localized: "Shell command completed")
        }
    }

    struct CommandExecution: Equatable, Identifiable {
        enum ExecutionState: Equatable {
            case running
            case succeeded
            case failed(String?)
            case cancelled
        }

        var id: UUID
        var deviceID: String
        var command: String
        var stdout = ""
        var stderr = ""
        var startedAt: Date
        var finishedAt: Date?
        var exitCode: Int32?
        var state = ExecutionState.running
        var wasTruncated = false
        var usedLegacyFallback = false

        var duration: TimeInterval? {
            finishedAt.map { $0.timeIntervalSince(startedAt) }
        }
    }

    @ObservableState
    struct State: Equatable {
        var activeDeviceID = DeviceIdentity.unknownID
        var commandInput = ""
        var history: [ShellHistoryEntry] = []
        var pinnedCommands: [String] = []
        var allHistory: [ShellHistoryEntry] = []
        var allPinnedCommands: [DeviceScopedPinnedCommand] = []
        var draftsByDeviceID: [String: String] = [:]
        var isExecuting = false
        var executionGeneration = 0
        var activeExecutionGeneration: Int?
        var activeExecution: CommandExecution?
        var selectedHistoryID: UUID?
        var pendingHistoryReuse: ShellHistoryEntry?
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

        /// Legacy entries remain visible without being silently claimed by the
        /// currently connected device. Known entries from other devices stay
        /// out of the default device-scoped history.
        var visibleHistory: [ShellHistoryEntry] {
            let currentIDs = Set(history.map(\.id))
            let legacy = allHistory.filter {
                $0.originDeviceID == DeviceIdentity.unknownID && !currentIDs.contains($0.id)
            }
            return ShellFeature.retainedHistory((history + legacy).sorted { $0.timestamp > $1.timestamp })
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setActiveDevice(String?)
        case onAppear
        case executeCommand
        case cancelExecution
        case cancelAll
        case executeQuickCommand(String)
        case commandResult(generation: Int, command: String, Result<String, Error>)
        case executionBatch(
            generation: Int,
            stdout: Data,
            stderr: Data,
            usedLegacyFallback: Bool
        )
        case executionFinished(generation: Int, exitCode: Int32)
        case executionFailed(generation: Int, message: String)
        case selectHistory(UUID?)
        case requestHistoryReuse(UUID)
        case confirmHistoryReuse
        case cancelHistoryReuse
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
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    private let persistenceWriter = ShellPersistenceWriter()

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.didLoadPersistence else { return .none }
                return .send(.loadPersistence)

            case .binding:
                state.draftsByDeviceID[state.activeDeviceID] = state.commandInput
                return persist(&state)

            case .setActiveDevice(let deviceID):
                state.draftsByDeviceID[state.activeDeviceID] = state.commandInput
                state.activeDeviceID = deviceID ?? DeviceIdentity.unknownID
                state.pendingHistoryReuse = nil
                applyActiveWorkspace(to: &state)
                return persist(&state)

            case .loadPersistence:
                state.didLoadPersistence = true
                return .run { send in
                    await send(.persistenceLoaded(shellPersistenceClient.load()))
                }

            case .persistenceLoaded(let persisted):
                state.allHistory = Self.retainedHistory(persisted.history)
                state.allPinnedCommands = Self.retainedScopedPinnedCommands(persisted.pinnedCommands)
                state.draftsByDeviceID = persisted.draftsByDeviceID
                applyActiveWorkspace(to: &state)
                return .none

            case .executeCommand:
                let command = state.commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty, !state.isExecuting else { return .none }
                state.commandInput = ""
                guard command.utf8.count <= Self.maximumCommandBytes else {
                    state.history.insert(
                        ShellHistoryEntry(
                            command: String(command.prefix(256)) + "…",
                            output: String(localized: "Command exceeds iADB's 16 KiB safety limit."),
                            timestamp: Date(),
                            isError: true,
                            originDeviceID: state.activeDeviceID
                        ),
                        at: 0
                    )
                    state.history = Self.retainedHistory(state.history)
                    return persist(&state)
                }
                state.isExecuting = true
                state.executionGeneration += 1
                let generation = state.executionGeneration
                state.activeExecutionGeneration = generation
                state.activeExecution = CommandExecution(
                    id: uuid(),
                    deviceID: state.activeDeviceID,
                    command: command,
                    startedAt: date.now
                )
                PerformanceSignposts.shellExecution("start")

                return .run { send in
                    let stream = try await adbClient.openShellCommand(command)
                    let clock = ContinuousClock()
                    var lastEmission = clock.now
                    var stdout = Data()
                    var stderr = Data()
                    var usedLegacyFallback = false
                    for try await event in stream {
                        switch event {
                        case .stdout(let data): stdout.append(data)
                        case .stderr(let data): stderr.append(data)
                        case .legacyFallback: usedLegacyFallback = true
                        case .exit(let exitCode):
                            if !stdout.isEmpty || !stderr.isEmpty || usedLegacyFallback {
                                await send(.executionBatch(
                                    generation: generation,
                                    stdout: stdout,
                                    stderr: stderr,
                                    usedLegacyFallback: usedLegacyFallback
                                ))
                            }
                            await send(.executionFinished(generation: generation, exitCode: exitCode))
                            return
                        }

                        if stdout.count + stderr.count >= 32 * 1024 ||
                            clock.now - lastEmission >= .milliseconds(125) {
                            await send(.executionBatch(
                                generation: generation,
                                stdout: stdout,
                                stderr: stderr,
                                usedLegacyFallback: usedLegacyFallback
                            ))
                            stdout.removeAll(keepingCapacity: true)
                            stderr.removeAll(keepingCapacity: true)
                            usedLegacyFallback = false
                            lastEmission = clock.now
                        }
                    }
                    await send(.executionFailed(
                        generation: generation,
                        message: String(localized: "The shell stream ended without an exit status.")
                    ))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.executionFailed(
                        generation: generation,
                        message: error.localizedDescription
                    ))
                }
                .cancellable(id: CancelID.execution, cancelInFlight: true)

            case .cancelExecution:
                guard state.isExecuting else { return .none }
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                if var execution = state.activeExecution {
                    execution.state = .cancelled
                    execution.finishedAt = date.now
                    state.activeExecution = execution
                    addExecutionToHistory(execution, state: &state)
                }
                return .merge(
                    .cancel(id: CancelID.execution),
                    persist(&state)
                )

            case .cancelAll:
                let hadRunningExecution = state.activeExecution?.state == .running
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                if var execution = state.activeExecution, hadRunningExecution {
                    execution.state = .cancelled
                    execution.finishedAt = date.now
                    state.activeExecution = execution
                    addExecutionToHistory(execution, state: &state)
                }
                guard hadRunningExecution else {
                    return .cancel(id: CancelID.execution)
                }
                return .merge(.cancel(id: CancelID.execution), persist(&state))

            case .executeQuickCommand(let command):
                state.commandInput = command
                return .send(.executeCommand)

            case .useHistoryCommand(let command):
                state.commandInput = command
                return .none

            case .executionBatch(
                let generation,
                let stdout,
                let stderr,
                let usedLegacyFallback
            ):
                guard state.activeExecutionGeneration == generation,
                      var execution = state.activeExecution else { return .none }
                let stdoutResult = Self.appendingBoundedOutput(
                    stdout,
                    to: execution.stdout,
                    otherBytes: execution.stderr.utf8.count
                )
                execution.stdout = stdoutResult.value
                execution.wasTruncated = execution.wasTruncated || stdoutResult.wasTruncated
                let stderrResult = Self.appendingBoundedOutput(
                    stderr,
                    to: execution.stderr,
                    otherBytes: execution.stdout.utf8.count
                )
                execution.stderr = stderrResult.value
                execution.wasTruncated = execution.wasTruncated || stderrResult.wasTruncated
                execution.usedLegacyFallback = execution.usedLegacyFallback || usedLegacyFallback
                state.activeExecution = execution
                return .none

            case .executionFinished(let generation, let exitCode):
                guard state.activeExecutionGeneration == generation,
                      var execution = state.activeExecution else { return .none }
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                execution.exitCode = exitCode
                execution.finishedAt = date.now
                execution.state = exitCode == 0 ? .succeeded : .failed(nil)
                state.activeExecution = execution
                addExecutionToHistory(execution, state: &state)
                PerformanceSignposts.shellExecution(exitCode == 0 ? "success" : "failed")
                return persist(&state)

            case .executionFailed(let generation, let message):
                guard state.activeExecutionGeneration == generation,
                      var execution = state.activeExecution else { return .none }
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                let stderrResult = Self.appendingBoundedOutput(
                    Data(message.utf8),
                    to: execution.stderr,
                    otherBytes: execution.stdout.utf8.count
                )
                execution.stderr = stderrResult.value
                execution.wasTruncated = execution.wasTruncated || stderrResult.wasTruncated
                execution.finishedAt = date.now
                execution.state = .failed(message)
                state.activeExecution = execution
                addExecutionToHistory(execution, state: &state)
                PerformanceSignposts.shellExecution("failed")
                return persist(&state)

            case .selectHistory(let id):
                state.selectedHistoryID = id
                return .none

            case .requestHistoryReuse(let id):
                guard let entry = state.visibleHistory.first(where: { $0.id == id })
                    ?? state.allHistory.first(where: { $0.id == id }) else {
                    return .none
                }
                guard entry.originDeviceID == state.activeDeviceID else {
                    state.pendingHistoryReuse = entry
                    return .none
                }
                state.commandInput = entry.command
                state.draftsByDeviceID[state.activeDeviceID] = entry.command
                return persist(&state)

            case .confirmHistoryReuse:
                guard let entry = state.pendingHistoryReuse else { return .none }
                state.pendingHistoryReuse = nil
                state.commandInput = entry.command
                state.draftsByDeviceID[state.activeDeviceID] = entry.command
                return persist(&state)

            case .cancelHistoryReuse:
                state.pendingHistoryReuse = nil
                return .none

            case .commandResult(let generation, let command, .success(let output)):
                guard state.activeExecutionGeneration == generation else { return .none }
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                PerformanceSignposts.shellExecution("success")
                let entry = ShellHistoryEntry(
                    command: command,
                    output: Self.truncatedOutput(output),
                    timestamp: Date(),
                    isError: false,
                    originDeviceID: state.activeDeviceID
                )
                state.history.insert(entry, at: 0)
                state.history = Self.retainedHistory(state.history)
                state.allHistory.insert(entry, at: 0)
                state.allHistory = Self.retainedHistory(state.allHistory)
                return persist(&state)

            case .commandResult(let generation, let command, .failure(let error)):
                guard state.activeExecutionGeneration == generation else { return .none }
                state.isExecuting = false
                state.activeExecutionGeneration = nil
                PerformanceSignposts.shellExecution("failed")
                let entry = ShellHistoryEntry(
                    command: command,
                    output: Self.truncatedOutput(error.localizedDescription),
                    timestamp: Date(),
                    isError: true,
                    originDeviceID: state.activeDeviceID
                )
                state.history.insert(entry, at: 0)
                state.history = Self.retainedHistory(state.history)
                state.allHistory.insert(entry, at: 0)
                state.allHistory = Self.retainedHistory(state.allHistory)
                return persist(&state)

            case .clearHistory:
                let activeDeviceID = state.activeDeviceID
                state.history.removeAll()
                state.allHistory.removeAll { $0.originDeviceID == activeDeviceID }
                return persist(&state)

            case .togglePinnedCommand(let command):
                if let index = state.pinnedCommands.firstIndex(of: command) {
                    let activeDeviceID = state.activeDeviceID
                    state.pinnedCommands.remove(at: index)
                    state.allPinnedCommands.removeAll {
                        $0.originDeviceID == activeDeviceID && $0.command == command
                    }
                } else {
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumCommandBytes else {
                        state.errorMessage = String(localized: "This command is too large to pin.")
                        return .none
                    }
                    state.pinnedCommands = Self.retainedPinnedCommands([trimmed] + state.pinnedCommands)
                    state.allPinnedCommands.insert(
                        DeviceScopedPinnedCommand(
                            id: uuid(),
                            command: trimmed,
                            originDeviceID: state.activeDeviceID
                        ),
                        at: 0
                    )
                    state.allPinnedCommands = Self.retainedScopedPinnedCommands(state.allPinnedCommands)
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

    private func addExecutionToHistory(
        _ execution: CommandExecution,
        state: inout State
    ) {
        var output = execution.stdout
        if !execution.stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += execution.stderr
        }
        if output.isEmpty, execution.state == .cancelled {
            output = String(localized: "Command interrupted.")
        }
        let entry = ShellHistoryEntry(
            id: execution.id,
            command: execution.command,
            output: output,
            timestamp: execution.startedAt,
            isError: execution.exitCode != 0 || execution.state != .succeeded,
            originDeviceID: execution.deviceID,
            stdout: execution.stdout,
            stderr: execution.stderr,
            exitCode: execution.exitCode,
            duration: execution.duration,
            wasTruncated: execution.wasTruncated,
            usedLegacyFallback: execution.usedLegacyFallback
        )
        state.history.removeAll { $0.id == entry.id }
        state.history.insert(entry, at: 0)
        state.history = Self.retainedHistory(state.history)
        state.allHistory.removeAll { $0.id == entry.id }
        state.allHistory.insert(entry, at: 0)
        state.allHistory = Self.retainedHistory(state.allHistory)
        state.selectedHistoryID = entry.id
    }

    private static func appendingBoundedOutput(
        _ data: Data,
        to existing: String,
        otherBytes: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard !data.isEmpty else { return (existing, false) }
        let remaining = max(0, maximumEntryOutputBytes - otherBytes - existing.utf8.count)
        guard remaining > 0 else { return (existing, true) }
        let accepted = data.prefix(remaining)
        return (
            existing + String(decoding: accepted, as: UTF8.self),
            accepted.count < data.count
        )
    }

    private func persist(_ state: inout State) -> Effect<Action> {
        synchronizeActiveWorkspace(in: &state)
        state.persistenceGeneration &+= 1
        let generation = state.persistenceGeneration
        let persisted = ShellPersistenceState(
            history: Self.retainedHistory(state.allHistory),
            scopedPinnedCommands: Self.retainedScopedPinnedCommands(state.allPinnedCommands),
            draftsByDeviceID: state.draftsByDeviceID
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
                String(localized: "Could not save shell history: \(error.localizedDescription)")
            ))
        }
    }

    static func truncatedOutput(_ output: String, byteLimit: Int = maximumEntryOutputBytes) -> String {
        guard output.utf8.count > byteLimit else { return output }
        let prefix = output.utf8.prefix(max(0, byteLimit))
        return String(decoding: prefix, as: UTF8.self) + String(localized: "\n… Output truncated by iADB …")
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

    static func retainedScopedPinnedCommands(
        _ commands: [DeviceScopedPinnedCommand]
    ) -> [DeviceScopedPinnedCommand] {
        var result: [DeviceScopedPinnedCommand] = []
        var seen = Set<String>()
        for command in commands {
            let value = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(command.originDeviceID)\u{0}\(value)"
            guard !value.isEmpty,
                  value.utf8.count <= maximumCommandBytes,
                  seen.insert(key).inserted,
                  result.count < maximumPinnedCommandCount else { continue }
            result.append(DeviceScopedPinnedCommand(
                id: command.id,
                command: value,
                originDeviceID: command.originDeviceID
            ))
        }
        return result
    }

    private func applyActiveWorkspace(to state: inout State) {
        state.history = Self.retainedHistory(
            state.allHistory.filter { $0.originDeviceID == state.activeDeviceID }
        )
        state.pinnedCommands = Self.retainedPinnedCommands(
            state.allPinnedCommands
                .filter { $0.originDeviceID == state.activeDeviceID }
                .map(\.command)
        )
        state.commandInput = state.draftsByDeviceID[state.activeDeviceID] ?? ""
    }

    private func synchronizeActiveWorkspace(in state: inout State) {
        let activeDeviceID = state.activeDeviceID
        state.allHistory.removeAll { $0.originDeviceID == activeDeviceID }
        state.allHistory.append(contentsOf: state.history.map {
            ShellHistoryEntry(
                id: $0.id,
                command: $0.command,
                output: $0.output,
                timestamp: $0.timestamp,
                isError: $0.isError,
                originDeviceID: activeDeviceID,
                stdout: $0.stdout,
                stderr: $0.stderr,
                exitCode: $0.exitCode,
                duration: $0.duration,
                wasTruncated: $0.wasTruncated,
                usedLegacyFallback: $0.usedLegacyFallback
            )
        })
        state.allHistory = Self.retainedHistory(
            state.allHistory.sorted { $0.timestamp > $1.timestamp }
        )

        let existingIDs = Dictionary(
            uniqueKeysWithValues: state.allPinnedCommands
                .filter { $0.originDeviceID == activeDeviceID }
                .map { ($0.command, $0.id) }
        )
        state.allPinnedCommands.removeAll { $0.originDeviceID == activeDeviceID }
        state.allPinnedCommands.append(contentsOf: state.pinnedCommands.map {
            DeviceScopedPinnedCommand(
                id: existingIDs[$0] ?? uuid(),
                command: $0,
                originDeviceID: activeDeviceID
            )
        })
        state.allPinnedCommands = Self.retainedScopedPinnedCommands(state.allPinnedCommands)
        state.draftsByDeviceID[activeDeviceID] = state.commandInput
    }
}
