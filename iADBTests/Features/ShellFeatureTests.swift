import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct ShellFeatureTests {
    @Test
    func outputAndHistoryAreBoundedBeforePersistence() {
        let output = String(repeating: "x", count: 32)
        let truncated = ShellFeature.truncatedOutput(output, byteLimit: 10)
        #expect(truncated.hasPrefix(String(repeating: "x", count: 10)))
        #expect(truncated.contains("truncated"))

        let entries = (0..<3).map { index in
            ShellHistoryEntry(
                command: "c\(index)",
                output: String(repeating: "y", count: 8),
                timestamp: Date(),
                isError: false
            )
        }
        #expect(ShellFeature.retainedHistory(entries, byteLimit: 15).count == 1)

        let pins = [" df -h ", "df -h", "", "getprop", "logcat"]
        #expect(ShellFeature.retainedPinnedCommands(pins, countLimit: 2, byteLimit: 20) == ["df -h", "getprop"])
    }

    @Test
    func executeCommandSuccess() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "ls /sdcard")
        ) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "file1.txt\nfile2.txt" }
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.executeCommand) {
            $0.commandInput = ""
            $0.isExecuting = true
        }

        // ShellHistoryEntry has random UUID + Date, use non-exhaustive
        store.exhaustivity = .off
        await store.receive(\.commandResult)
        store.exhaustivity = .on

        #expect(store.state.isExecuting == false)
        #expect(store.state.history.count == 1)
        #expect(store.state.history[0].command == "ls /sdcard")
        #expect(store.state.history[0].output == "file1.txt\nfile2.txt")
        #expect(store.state.history[0].isError == false)
    }

    @Test
    func executeCommandError() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "bad_cmd")
        ) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in throw ADBError.commandFailed("not found") }
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.executeCommand) {
            $0.commandInput = ""
            $0.isExecuting = true
        }

        store.exhaustivity = .off
        await store.receive(\.commandResult)
        store.exhaustivity = .on

        #expect(store.state.isExecuting == false)
        #expect(store.state.history.count == 1)
        #expect(store.state.history[0].isError == true)
    }

    @Test
    func executeCommandEmpty() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "   ")
        ) {
            ShellFeature()
        }

        await store.send(.executeCommand)
        // No effect — empty command after trim
    }

    @Test
    func executeQuickCommand() async {
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in "output" }
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.executeQuickCommand("df -h")) {
            $0.commandInput = "df -h"
        }

        store.exhaustivity = .off
        await store.receive(\.executeCommand)
        await store.receive(\.commandResult)
        store.exhaustivity = .on

        #expect(store.state.history.count == 1)
        #expect(store.state.history[0].command == "df -h")
    }

    @Test
    func clearHistory() async {
        let entry = ShellHistoryEntry(command: "ls", output: ".", timestamp: Date(), isError: false)
        let store = TestStore(
            initialState: ShellFeature.State(history: [entry])
        ) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.clearHistory) {
            $0.history = []
            $0.persistenceGeneration = 1
        }
    }

    @Test
    func executeCommandIgnoredWhileExecuting() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "ls", isExecuting: true)
        ) {
            ShellFeature()
        }

        await store.send(.executeCommand)
    }

    @Test
    func cancelExecutionRestoresInteractiveState() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "logcat")
        ) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.shell = { _ in
                try await Task.sleep(for: .seconds(60))
                return ""
            }
        }

        await store.send(.executeCommand) {
            $0.commandInput = ""
            $0.isExecuting = true
        }
        await store.send(.cancelExecution) {
            $0.isExecuting = false
        }
    }

    @Test
    func historyOrder() async {
        let store = TestStore(initialState: ShellFeature.State(commandInput: "cmd1")) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.shell = { cmd in "out-\(cmd)" }
            $0.shellPersistenceClient.save = { _ in }
        }

        store.exhaustivity = .off

        // Execute first command
        await store.send(.executeCommand)
        await store.receive(\.commandResult)

        // Execute second command
        await store.send(.binding(.set(\.commandInput, "cmd2")))
        await store.send(.executeCommand)
        await store.receive(\.commandResult)

        store.exhaustivity = .on

        #expect(store.state.history.count == 2)
        #expect(store.state.history[0].command == "cmd2") // newest first
        #expect(store.state.history[1].command == "cmd1")
    }

    @Test
    func onAppearLoadsPersistence() async {
        let entry = ShellHistoryEntry(command: "getprop", output: "Pixel", timestamp: Date(), isError: false)
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.load = {
                ShellPersistenceState(history: [entry], pinnedCommands: ["df -h"])
            }
        }

        await store.send(.onAppear)
        await store.receive(\.loadPersistence) {
            $0.didLoadPersistence = true
        }
        await store.receive(\.persistenceLoaded) {
            $0.history = [entry]
            $0.pinnedCommands = ["df -h"]
        }
    }

    @Test
    func togglePinnedCommand() async {
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = ["df -h"]
            $0.persistenceGeneration = 1
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = []
            $0.persistenceGeneration = 2
        }
    }

    @Test
    func persistenceFailureIsVisible() async {
        struct DiskError: LocalizedError {
            var errorDescription: String? { "disk is full" }
        }
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in throw DiskError() }
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = ["df -h"]
            $0.persistenceGeneration = 1
        }
        await store.receive(\.persistenceFailed) {
            $0.errorMessage = "Could not save shell history: disk is full"
        }
        await store.send(.dismissError) {
            $0.errorMessage = nil
        }
    }

    @Test
    func useHistoryCommand() async {
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        }

        await store.send(.useHistoryCommand("pm list packages")) {
            $0.commandInput = "pm list packages"
        }
    }

    @Test
    func persistenceWriterRejectsSnapshotThatArrivesOutOfOrder() async throws {
        let recorder = ShellPersistenceRecorder()
        let client = ShellPersistenceClient(
            load: { ShellPersistenceState(history: [], pinnedCommands: []) },
            save: { recorder.append($0) }
        )
        let writer = ShellPersistenceWriter()
        let latest = ShellPersistenceState(history: [], pinnedCommands: ["latest"])
        let stale = ShellPersistenceState(history: [], pinnedCommands: ["stale"])

        try await writer.save(generation: 2, state: latest, client: client)
        try await writer.save(generation: 1, state: stale, client: client)

        #expect(recorder.values == [latest])
    }
}

private final class ShellPersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ShellPersistenceState] = []

    var values: [ShellPersistenceState] {
        lock.withLock { storage }
    }

    func append(_ state: ShellPersistenceState) {
        lock.withLock { storage.append(state) }
    }
}
