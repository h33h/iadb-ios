import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct LogcatFeatureTests {
    @Test
    func fragmentedUTF8ScalarIsPreservedAcrossTransportPackets() throws {
        let text = "01-01 00:00:00.000  1000  1001 I Test: hi🙂\n"
        let data = Data(text.utf8)
        let emojiStart = try #require(data.firstIndex(of: 0xF0))
        let splitIndex = data.index(emojiStart, offsetBy: 2)
        var buffer = LogcatChunkBuffer()

        let firstLines = appendLogcatChunk(Data(data[..<splitIndex]), to: &buffer)
        #expect(firstLines.isEmpty)

        let secondLines = appendLogcatChunk(Data(data[splitIndex...]), to: &buffer)
        #expect(secondLines == [String(text.dropLast())])
        #expect(buffer.data.isEmpty)
    }

    @Test
    func stopLogcat() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true)
        ) {
            LogcatFeature()
        }

        await store.send(.stopLogcat) {
            $0.isRunning = false
        }
    }

    @Test
    func logcatLinesAppended() async {
        let store = TestStore(initialState: LogcatFeature.State(isRunning: true)) {
            LogcatFeature()
        }

        let lines = [
            "01-01 00:00:00.000  1000  1001 I ActivityManager: Start proc",
            "01-01 00:00:00.001  1000  1002 D WindowManager: Relayout"
        ]

        // LogEntry generates UUID on init, can't match exactly
        store.exhaustivity = .off
        await store.send(.logcatLines(lines))
        store.exhaustivity = .on

        #expect(store.state.entries.count == 2)
        #expect(store.state.entries[0].tag == "ActivityManager")
        #expect(store.state.entries[1].tag == "WindowManager")
    }

    @Test
    func logcatLinesPausedBuffered() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true, isPaused: true)
        ) {
            LogcatFeature()
        }

        let line = "01-01 00:00:00.000  1000  1001 I Test: msg"
        await store.send(.logcatLines([line])) {
            $0.pauseBuffer = [line]
        }
        #expect(store.state.entries.isEmpty)
    }

    @Test
    func togglePauseAppliesBuffer() async {
        let line = "01-01 00:00:00.000  1000  1001 I Test: buffered"
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true, isPaused: true, pauseBuffer: [line])
        ) {
            LogcatFeature()
        }

        store.exhaustivity = .off
        await store.send(.togglePause) {
            $0.isPaused = false
            $0.pauseBuffer = []
        }
        store.exhaustivity = .on

        #expect(store.state.entries.count == 1)
        #expect(store.state.entries[0].tag == "Test")
    }

    @Test
    func maxEntriesLimit() async {
        let entries = (0..<100).map { _ in
            LogEntry(
                timestamp: "00:00:00",
                pid: "1000",
                tid: "1001",
                level: .info,
                tag: "Tag",
                message: "msg"
            )
        }
        let store = TestStore(
            initialState: LogcatFeature.State(entries: entries, isRunning: true, maxEntries: 110)
        ) {
            LogcatFeature()
        }

        let newLines = (100..<120).map { i in
            "01-01 00:00:00.000  1000  1001 I Tag: msg \(i)"
        }

        store.exhaustivity = .off
        await store.send(.logcatLines(newLines))
        store.exhaustivity = .on

        // 100 + 20 = 120, trimmed to maxEntries=110
        #expect(store.state.entries.count == 110)
    }

    @Test
    func completeAndPausedLinesAreBoundedByBytes() async {
        let prefix = "01-01 00:00:00.000  1000  1001 I Tag: "
        let hugeLine = prefix + String(repeating: "x", count: 4_000)
        let store = TestStore(
            initialState: LogcatFeature.State(
                isRunning: true,
                maxEntries: 5_000,
                maxRetainedBytes: 700,
                maxLineBytes: 256
            )
        ) {
            LogcatFeature()
        }

        store.exhaustivity = .off
        await store.send(.logcatLines(Array(repeating: hugeLine, count: 20)))
        store.exhaustivity = .on

        #expect(store.state.entries.count < 20)
        #expect(store.state.entries.allSatisfy { $0.message.utf8.count < 400 })
        #expect(LogcatFeature.exportString(store.state.entries, byteLimit: 700).utf8.count <= 700)

        await store.send(.togglePause) {
            $0.isPaused = true
        }
        store.exhaustivity = .off
        await store.send(.logcatLines(Array(repeating: hugeLine, count: 20)))
        store.exhaustivity = .on
        #expect(store.state.pauseBuffer.reduce(0) { $0 + $1.utf8.count + 1 } <= 700)
    }

    @Test
    func oversizedFragmentedLineIsTruncatedWithoutGrowingBuffer() {
        var buffer = LogcatChunkBuffer()
        let first = appendLogcatChunk(Data(repeating: 0x61, count: 2_000), to: &buffer, lineByteLimit: 128)
        #expect(first.isEmpty)
        #expect(buffer.data.count == 128)

        let completed = appendLogcatChunk(Data([0x62, 0x63, 0x0A]), to: &buffer, lineByteLimit: 128)
        #expect(completed.count == 1)
        #expect(completed[0].contains("truncated"))
        #expect(buffer.data.isEmpty)
    }

    @Test
    func clearLog() async {
        let entry = LogEntry(
            timestamp: "00:00:00",
            pid: "1",
            tid: "1",
            level: .info,
            tag: "Test",
            message: "msg"
        )
        let store = TestStore(
            initialState: LogcatFeature.State(entries: [entry], pauseBuffer: ["buffered"])
        ) {
            LogcatFeature()
        }

        await store.send(.clearLog) {
            $0.entries = []
            $0.pauseBuffer = []
        }
    }

    @Test
    func togglePause() async {
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        }

        await store.send(.togglePause) {
            $0.isPaused = true
        }
    }

    @Test
    func filteredEntries() {
        let entries = [
            LogEntry(timestamp: "00:00:00", pid: "1", tid: "1", level: .info, tag: "ActivityManager", message: "Start proc"),
            LogEntry(timestamp: "00:00:01", pid: "1", tid: "1", level: .debug, tag: "WindowManager", message: "Relayout"),
            LogEntry(timestamp: "00:00:02", pid: "1", tid: "1", level: .error, tag: "System", message: "Error occurred"),
        ]

        // Filter by level
        var state = LogcatFeature.State(entries: entries, selectedLevel: .error)
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "System")

        // Filter by text
        state = LogcatFeature.State(entries: entries, filterText: "Window")
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "WindowManager")

        // Both filters
        state = LogcatFeature.State(entries: entries, filterText: "Error", selectedLevel: .error)
        #expect(state.filteredEntries.count == 1)
    }

    @Test
    func onAppearLoadsPersistence() async {
        let preset = LogcatPreset(name: "Errors", filterText: "", level: .error)
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.load = {
                LogcatPersistenceState(filterText: "ActivityManager", selectedLevel: .warning, presets: [preset])
            }
        }

        await store.send(.onAppear)
        await store.receive(\.loadPersistence) {
            $0.didLoadPersistence = true
        }
        await store.receive(\.persistenceLoaded) {
            $0.filterText = "ActivityManager"
            $0.selectedLevel = .warning
            $0.savedPresets = [preset]
        }
    }

    @Test
    func oversizedPersistenceIsSanitizedBeforeReachingUI() async {
        let hugeText = String(repeating: "🙂", count: 2_000)
        let presets = (0..<75).map { index in
            LogcatPreset(
                name: "Preset \(index) " + hugeText,
                filterText: hugeText,
                level: .debug
            )
        }
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.load = {
                LogcatPersistenceState(
                    filterText: hugeText,
                    selectedLevel: .warning,
                    presets: presets
                )
            }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.loadPersistence)
        await store.receive(\.persistenceLoaded)

        #expect(store.state.filterText.utf8.count <= LogcatPersistenceState.maximumTextBytes)
        #expect(store.state.savedPresets.count <= LogcatPersistenceState.maximumPresetCount)
        #expect(store.state.savedPresets.allSatisfy {
            $0.name.utf8.count <= LogcatPersistenceState.maximumTextBytes &&
                $0.filterText.utf8.count <= LogcatPersistenceState.maximumTextBytes
        })
        let persisted = LogcatPersistenceState(
            filterText: store.state.filterText,
            selectedLevel: store.state.selectedLevel,
            presets: store.state.savedPresets
        )
        #expect(persisted.encodedForPersistence()?.count ?? .max <= LogcatPersistenceState.maximumBlobBytes)
    }

    @Test
    func filterAndPresetInputBindingsAreByteBounded() async {
        let hugeText = String(repeating: "🙂", count: 2_000)
        let expected = LogcatPersistenceState.boundedText(hugeText)
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.save = { _ in }
        }

        await store.send(.binding(.set(\.filterText, hugeText))) {
            $0.filterText = expected
        }
        await store.send(.binding(.set(\.presetNameInput, hugeText))) {
            $0.presetNameInput = expected
        }

        #expect(store.state.filterText.utf8.count <= LogcatPersistenceState.maximumTextBytes)
        #expect(store.state.presetNameInput.utf8.count <= LogcatPersistenceState.maximumTextBytes)
    }

    @Test
    func userDefaultsPersistenceRejectsOversizedBlobAndBoundsSaves() throws {
        let suiteName = "LogcatPersistenceClientTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "logcat"
        let client = LogcatPersistenceClient.userDefaultsClient(defaults: defaults, key: key)

        defaults.set(
            Data(repeating: 0x41, count: LogcatPersistenceState.maximumBlobBytes + 1),
            forKey: key
        )
        #expect(client.load() == .empty)
        #expect(defaults.data(forKey: key) == nil)

        let hugeText = String(repeating: "🙂", count: 2_000)
        let oversizedState = LogcatPersistenceState(
            filterText: hugeText,
            selectedLevel: .error,
            presets: (0..<80).map { index in
                LogcatPreset(
                    name: "Preset \(index) " + hugeText,
                    filterText: hugeText,
                    level: .error
                )
            }
        )
        client.save(oversizedState)

        let storedData = try #require(defaults.data(forKey: key))
        #expect(storedData.count <= LogcatPersistenceState.maximumBlobBytes)
        let storedState = try JSONDecoder().decode(LogcatPersistenceState.self, from: storedData)
        #expect(storedState.filterText.utf8.count <= LogcatPersistenceState.maximumTextBytes)
        #expect(storedState.presets.count <= LogcatPersistenceState.maximumPresetCount)
        #expect(storedState.presets.allSatisfy {
            $0.name.utf8.count <= LogcatPersistenceState.maximumTextBytes &&
                $0.filterText.utf8.count <= LogcatPersistenceState.maximumTextBytes
        })
    }

    @Test
    func saveApplyAndDeletePreset() async throws {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(initialState: LogcatFeature.State(filterText: "Window", selectedLevel: .error, presetNameInput: "Errors")) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.save = { _ in }
            $0.uuid = .constant(presetID)
        }

        await store.send(.savePreset) {
            $0.savedPresets = [LogcatPreset(id: presetID, name: "Errors", filterText: "Window", level: .error)]
            $0.presetNameInput = ""
        }

        let preset = try #require(store.state.savedPresets.first)
        #expect(store.state.savedPresets.count == 1)

        await store.send(.applyPreset(LogcatPreset(name: "All Warnings", filterText: "Activity", level: .warning))) {
            $0.filterText = "Activity"
            $0.selectedLevel = .warning
        }

        await store.send(.deletePreset(preset.id)) {
            $0.savedPresets = []
        }
    }

    @Test
    func logcatStopped() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true)
        ) {
            LogcatFeature()
        }

        await store.send(.logcatStopped) {
            $0.isRunning = false
        }
    }

    @Test
    func streamFailureIsVisibleAndRecoverable() async {
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        } withDependencies: {
            $0.adbClient.openLogcatStream = { throw ADBError.notConnected }
        }

        await store.send(.startLogcat) {
            $0.isRunning = true
            $0.entries = []
            $0.pauseBuffer = []
            $0.isPaused = false
            $0.errorMessage = nil
        }
        await store.receive(\.logcatFailed) {
            $0.isRunning = false
            $0.isPaused = false
            $0.pauseBuffer = []
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
        await store.send(.dismissError) {
            $0.errorMessage = nil
        }
    }
}
