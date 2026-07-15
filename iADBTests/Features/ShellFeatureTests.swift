import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct ShellFeatureTests {
    private static let executionID = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
    private static let executionDate = Date(timeIntervalSince1970: 4_000)

    nonisolated private static func eventStream(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0
    ) -> AsyncThrowingStream<ShellEvent, Error> {
        AsyncThrowingStream { continuation in
            if !stdout.isEmpty { continuation.yield(.stdout(Data(stdout.utf8))) }
            if !stderr.isEmpty { continuation.yield(.stderr(Data(stderr.utf8))) }
            continuation.yield(.exit(exitCode))
            continuation.finish()
        }
    }

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
    func accessibilityAnnouncementTracksStartCompletionAndExitStatus() {
        let running = ShellFeature.CommandExecution(
            id: Self.executionID,
            deviceID: "device",
            command: "false",
            startedAt: Self.executionDate
        )
        var failed = running
        failed.state = .failed(nil)
        failed.exitCode = 7

        #expect(ShellFeature.accessibilityAnnouncement(
            wasExecuting: false,
            isExecuting: true,
            execution: running
        ) == "Shell command started")
        #expect(ShellFeature.accessibilityAnnouncement(
            wasExecuting: true,
            isExecuting: false,
            execution: failed
        ) == "Shell command completed with exit code 7")
        #expect(ShellFeature.accessibilityAnnouncement(
            wasExecuting: false,
            isExecuting: false,
            execution: failed
        ) == nil)
    }

    @Test
    func streamingStderrAndNonZeroExitRemainDistinct() async {
        let store = TestStore(initialState: ShellFeature.State(commandInput: "failing-command")) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.openShellCommand = { _ in
                Self.eventStream(stdout: "partial output", stderr: "permission denied", exitCode: 7)
            }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }
        store.exhaustivity = .off

        await store.send(.executeCommand)
        await store.receive(\.executionBatch)
        #expect(store.state.isExecuting)
        #expect(store.state.activeExecution?.stdout == "partial output")
        #expect(store.state.activeExecution?.stderr == "permission denied")
        await store.receive(\.executionFinished)
        store.exhaustivity = .on

        let entry = store.state.history.first
        #expect(entry?.stdout == "partial output")
        #expect(entry?.stderr == "permission denied")
        #expect(entry?.exitCode == 7)
        #expect(entry?.isError == true)
    }

    @Test
    func streamingOutputIsBoundedAndMarksTruncation() async {
        let oversized = String(repeating: "x", count: ShellFeature.maximumEntryOutputBytes + 512)
        let store = TestStore(initialState: ShellFeature.State(commandInput: "large-output")) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.openShellCommand = { _ in Self.eventStream(stdout: oversized) }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }
        store.exhaustivity = .off

        await store.send(.executeCommand)
        await store.receive(\.executionBatch)
        await store.receive(\.executionFinished)
        store.exhaustivity = .on

        #expect(store.state.history.first?.stdout.utf8.count == ShellFeature.maximumEntryOutputBytes)
        #expect(store.state.history.first?.wasTruncated == true)
    }

    @Test
    func staleStreamingEventCannotMutateNewExecution() async {
        let current = ShellFeature.CommandExecution(
            id: Self.executionID,
            deviceID: "device-a",
            command: "current",
            startedAt: Self.executionDate
        )
        let store = TestStore(initialState: ShellFeature.State(
            isExecuting: true,
            executionGeneration: 2,
            activeExecutionGeneration: 2,
            activeExecution: current
        )) {
            ShellFeature()
        }

        await store.send(.executionBatch(
            generation: 1,
            stdout: Data("stale".utf8),
            stderr: Data(),
            usedLegacyFallback: false
        ))
        #expect(store.state.activeExecution == current)
    }

    @Test
    func executeCommandSuccess() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "ls /sdcard")
        ) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.openShellCommand = { _ in
                Self.eventStream(stdout: "file1.txt\nfile2.txt")
            }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }

        store.exhaustivity = .off
        await store.send(.executeCommand)
        await store.receive(\.executionBatch)
        await store.receive(\.executionFinished)
        store.exhaustivity = .on

        #expect(store.state.isExecuting == false)
        #expect(store.state.history.count == 1)
        #expect(store.state.history[0].command == "ls /sdcard")
        #expect(store.state.history[0].output == "file1.txt\nfile2.txt")
        #expect(store.state.history[0].exitCode == 0)
        #expect(store.state.history[0].isError == false)
    }

    @Test
    func executeCommandError() async {
        let store = TestStore(
            initialState: ShellFeature.State(commandInput: "bad_cmd")
        ) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.openShellCommand = { _ in
                AsyncThrowingStream { $0.finish(throwing: ADBError.commandFailed("not found")) }
            }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }

        store.exhaustivity = .off
        await store.send(.executeCommand)
        await store.receive(\.executionFailed)
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
            $0.adbClient.openShellCommand = { _ in Self.eventStream(stdout: "output") }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }

        await store.send(.executeQuickCommand("df -h")) {
            $0.commandInput = "df -h"
        }

        store.exhaustivity = .off
        await store.receive(\.executeCommand)
        await store.receive(\.executionBatch)
        await store.receive(\.executionFinished)
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
            $0.draftsByDeviceID[DeviceIdentity.unknownID] = ""
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
            $0.adbClient.openShellCommand = { _ in
                AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in }
                }
            }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(Self.executionID)
            $0.date.now = Self.executionDate
        }

        store.exhaustivity = .off
        await store.send(.executeCommand)
        await store.send(.cancelExecution)
        store.exhaustivity = .on
        #expect(store.state.history.first?.output == "Command interrupted.")
    }

    @Test
    func historyOrder() async {
        let store = TestStore(initialState: ShellFeature.State(commandInput: "cmd1")) {
            ShellFeature()
        } withDependencies: {
            $0.adbClient.openShellCommand = { cmd in Self.eventStream(stdout: "out-\(cmd)") }
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .incrementing
            $0.date.now = Self.executionDate
        }

        store.exhaustivity = .off

        // Execute first command
        await store.send(.executeCommand)
        await store.receive(\.executionBatch)
        await store.receive(\.executionFinished)

        // Execute second command
        await store.send(.binding(.set(\.commandInput, "cmd2")))
        await store.send(.executeCommand)
        await store.receive(\.executionBatch)
        await store.receive(\.executionFinished)

        store.exhaustivity = .on

        #expect(store.state.history.count == 2)
        #expect(store.state.history[0].command == "cmd2") // newest first
        #expect(store.state.history[1].command == "cmd1")
    }

    @Test
    func onAppearLoadsPersistence() async {
        let entry = ShellHistoryEntry(command: "getprop", output: "Pixel", timestamp: Date(), isError: false)
        let persisted = ShellPersistenceState(history: [entry], pinnedCommands: ["df -h"])
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.load = { persisted }
        }

        await store.send(.onAppear)
        await store.receive(\.loadPersistence) {
            $0.didLoadPersistence = true
        }
        await store.receive(\.persistenceLoaded) {
            $0.history = [entry]
            $0.pinnedCommands = ["df -h"]
            $0.allHistory = [entry]
            $0.allPinnedCommands = persisted.pinnedCommands
        }
    }

    @Test
    func legacyUnknownDeviceHistoryRemainsVisibleWithoutChangingOrigin() async {
        let entry = ShellHistoryEntry(
            command: "getprop",
            output: "legacy",
            timestamp: Date(timeIntervalSince1970: 1),
            isError: false
        )
        let persisted = ShellPersistenceState(history: [entry], pinnedCommands: [])
        let store = TestStore(initialState: ShellFeature.State(activeDeviceID: "guid:current")) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.load = { persisted }
        }

        await store.send(.loadPersistence) {
            $0.didLoadPersistence = true
        }
        await store.receive(\.persistenceLoaded) {
            $0.allHistory = [entry]
        }
        #expect(store.state.history.isEmpty)
        #expect(store.state.visibleHistory == [entry])
        #expect(store.state.visibleHistory.first?.originDeviceID == DeviceIdentity.unknownID)
    }

    @Test
    func deviceSwitchScopesHistoryPinsAndDraft() async {
        let deviceA = "guid:a"
        let deviceB = "guid:b"
        let entryA = ShellHistoryEntry(
            command: "echo a",
            output: "a",
            timestamp: Date(timeIntervalSince1970: 1),
            isError: false,
            originDeviceID: deviceA
        )
        let entryB = ShellHistoryEntry(
            command: "echo b",
            output: "b",
            timestamp: Date(timeIntervalSince1970: 2),
            isError: false,
            originDeviceID: deviceB
        )
        let persisted = ShellPersistenceState(
            history: [entryB, entryA],
            scopedPinnedCommands: [
                DeviceScopedPinnedCommand(command: "pin-a", originDeviceID: deviceA),
                DeviceScopedPinnedCommand(command: "pin-b", originDeviceID: deviceB),
            ],
            draftsByDeviceID: [deviceA: "draft-a", deviceB: "draft-b"]
        )
        let store = TestStore(
            initialState: ShellFeature.State(activeDeviceID: deviceA)
        ) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.load = { persisted }
            $0.shellPersistenceClient.save = { _ in }
        }

        store.exhaustivity = .off
        await store.send(.loadPersistence)
        await store.receive(\.persistenceLoaded)
        store.exhaustivity = .on
        #expect(store.state.history == [entryA])
        #expect(store.state.pinnedCommands == ["pin-a"])
        #expect(store.state.commandInput == "draft-a")

        store.exhaustivity = .off
        await store.send(.setActiveDevice(deviceB))
        store.exhaustivity = .on
        #expect(store.state.history == [entryB])
        #expect(store.state.pinnedCommands == ["pin-b"])
        #expect(store.state.commandInput == "draft-b")
    }

    @Test
    func togglePinnedCommand() async {
        let pinnedID = UUID(0)
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in }
            $0.uuid = .constant(pinnedID)
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = ["df -h"]
            $0.allPinnedCommands = [DeviceScopedPinnedCommand(
                id: pinnedID,
                command: "df -h",
                originDeviceID: DeviceIdentity.unknownID
            )]
            $0.draftsByDeviceID[DeviceIdentity.unknownID] = ""
            $0.persistenceGeneration = 1
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = []
            $0.allPinnedCommands = []
            $0.persistenceGeneration = 2
        }
    }

    @Test
    func persistenceFailureIsVisible() async {
        let pinnedID = UUID(0)
        struct DiskError: LocalizedError {
            var errorDescription: String? { "disk is full" }
        }
        let store = TestStore(initialState: ShellFeature.State()) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in throw DiskError() }
            $0.uuid = .constant(pinnedID)
        }

        await store.send(.togglePinnedCommand("df -h")) {
            $0.pinnedCommands = ["df -h"]
            $0.allPinnedCommands = [DeviceScopedPinnedCommand(
                id: pinnedID,
                command: "df -h",
                originDeviceID: DeviceIdentity.unknownID
            )]
            $0.draftsByDeviceID[DeviceIdentity.unknownID] = ""
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
    func staleCommandCompletionIsIgnoredAfterCancelOrReconnect() async {
        let store = TestStore(initialState: ShellFeature.State(
            isExecuting: true,
            executionGeneration: 2,
            activeExecutionGeneration: 2
        )) {
            ShellFeature()
        }

        await store.send(.commandResult(
            generation: 1,
            command: "rm -rf /stale",
            .success("unexpected")
        ))
        #expect(store.state.history.isEmpty)
        #expect(store.state.isExecuting)
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
    func commandFromAnotherDeviceRequiresExplicitReuseConfirmation() async {
        let entry = ShellHistoryEntry(
            command: "reboot",
            output: "",
            timestamp: Date(timeIntervalSince1970: 1),
            isError: false,
            originDeviceID: "guid:other-device"
        )
        let store = TestStore(initialState: ShellFeature.State(
            activeDeviceID: "guid:current-device",
            allHistory: [entry]
        )) {
            ShellFeature()
        } withDependencies: {
            $0.shellPersistenceClient.save = { _ in }
        }

        await store.send(.requestHistoryReuse(entry.id)) {
            $0.pendingHistoryReuse = entry
        }
        #expect(store.state.commandInput.isEmpty)
        #expect(store.state.isExecuting == false)

        await store.send(.confirmHistoryReuse) {
            $0.pendingHistoryReuse = nil
            $0.commandInput = "reboot"
            $0.draftsByDeviceID["guid:current-device"] = "reboot"
            $0.persistenceGeneration = 1
        }
        #expect(store.state.isExecuting == false)
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
