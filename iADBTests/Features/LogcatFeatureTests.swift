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
            initialState: LogcatFeature.State(captureState: .live)
        ) {
            LogcatFeature()
        }

        await store.send(.stopLogcat) {
            $0.captureState = .stopped
        }
    }

    @Test
    func logcatLinesAppended() async {
        let store = TestStore(initialState: LogcatFeature.State(captureState: .live)) {
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
    func viewportPauseKeepsCaptureLiveAndCountsNewEntries() async {
        let store = TestStore(
            initialState: LogcatFeature.State(
                captureState: .live,
                followState: .paused(newCount: 0)
            )
        ) {
            LogcatFeature()
        }

        let line = "01-01 00:00:00.000  1000  1001 I Test: msg"
        store.exhaustivity = .off
        await store.send(.logcatLines([line]))
        store.exhaustivity = .on
        #expect(store.state.entries.count == 1)
        #expect(store.state.followState == .paused(newCount: 1))
        #expect(store.state.captureState == .live)
    }

    @Test
    func resumeFollowingKeepsSingleRingBuffer() async {
        let entry = LogEntry(
            timestamp: "01-01 00:00:00.000",
            pid: "1000",
            tid: "1001",
            level: .info,
            tag: "Test",
            message: "retained"
        )
        let store = TestStore(
            initialState: LogcatFeature.State(
                entries: [entry],
                captureState: .live,
                followState: .paused(newCount: 1)
            )
        ) {
            LogcatFeature()
        }

        await store.send(.togglePause) {
            $0.followState = .following
        }

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
            initialState: LogcatFeature.State(
                entries: entries,
                captureState: .live,
                maxEntries: 110
            )
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
    func ringBufferReportsExactDroppedCountAndKeepsStableOrder() async {
        let lines = (0..<8).map { index in
            "01-01 00:00:00.00\(index)  1000  1001 I Tag: message-\(index)"
        }
        let store = TestStore(initialState: LogcatFeature.State(
            captureState: .live,
            maxEntries: 5
        )) {
            LogcatFeature()
        }
        store.exhaustivity = .off

        await store.send(.logcatLines(Array(lines.prefix(4))))
        await store.send(.logcatLines(Array(lines.suffix(4))))

        #expect(store.state.entries.map(\.message) == (3..<8).map { "message-\($0)" })
        #expect(store.state.droppedCount == 3)
        #expect(store.state.captureState == .live)
    }

    @Test
    func incomingBatchPreservesSelectionAndViewportState() async {
        let selected = LogEntry(
            timestamp: "01-01 00:00:00.000",
            pid: "1000",
            tid: "1001",
            level: .info,
            tag: "Selected",
            message: "VoiceOver focus anchor"
        )
        let store = TestStore(initialState: LogcatFeature.State(
            entries: [selected],
            captureState: .live,
            followState: .paused(newCount: 4),
            selectedEntryID: selected.id
        )) {
            LogcatFeature()
        }
        store.exhaustivity = .off

        await store.send(.logcatLines([
            "01-01 00:00:00.001  1000  1002 D Incoming: first",
            "01-01 00:00:00.002  1000  1003 E Incoming: second"
        ]))

        #expect(store.state.entries.map(\.tag) == ["Selected", "Incoming", "Incoming"])
        #expect(store.state.selectedEntryID == selected.id)
        #expect(store.state.followState == .paused(newCount: 6))
        #expect(store.state.captureState == .live)
    }

    @Test
    func filterChangesDoNotAffectCaptureOrFollowState() async {
        let store = TestStore(initialState: LogcatFeature.State(
            captureState: .live,
            followState: .paused(newCount: 12)
        )) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.save = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.binding(.set(\.filterText, "ActivityManager")))

        #expect(store.state.captureState == .live)
        #expect(store.state.followState == .paused(newCount: 12))
    }

    @Test
    func completeAndPausedLinesAreBoundedByBytes() async {
        let prefix = "01-01 00:00:00.000  1000  1001 I Tag: "
        let hugeLine = prefix + String(repeating: "x", count: 4_000)
        let store = TestStore(
            initialState: LogcatFeature.State(
                captureState: .live,
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
            $0.followState = .paused(newCount: 0)
        }
        store.exhaustivity = .off
        await store.send(.logcatLines(Array(repeating: hugeLine, count: 20)))
        store.exhaustivity = .on
        #expect(store.state.retainedBytes <= 700)
        #expect(store.state.newEntryCount == 20)
        #expect(store.state.captureState == .live)
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
            initialState: LogcatFeature.State(
                entries: [entry],
                followState: .paused(newCount: 2),
                droppedCount: 3
            )
        ) {
            LogcatFeature()
        }

        await store.send(.clearLog) {
            $0.entries = []
            $0.followState = .paused(newCount: 0)
            $0.droppedCount = 0
        }
    }

    @Test
    func togglePause() async {
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        }

        await store.send(.togglePause) {
            $0.followState = .paused(newCount: 0)
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
        var state = LogcatFeature.State(
            entries: entries,
            filter: LogcatFilter(levels: [.error])
        )
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "System")

        // Filter by text
        state = LogcatFeature.State(entries: entries, filter: LogcatFilter(query: "Window"))
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "WindowManager")

        // Both filters
        state = LogcatFeature.State(
            entries: entries,
            filter: LogcatFilter(levels: [.error], query: "Error")
        )
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
            $0.allSavedPresets = [preset]
            $0.filtersByDeviceID = [
                DeviceIdentity.unknownID: LogcatFilterSettings(
                    filterText: "ActivityManager",
                    selectedLevel: .warning
                )
            ]
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
            $0.filtersByDeviceID[DeviceIdentity.unknownID] = LogcatFilterSettings(
                filterText: expected,
                selectedLevel: nil
            )
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
        #expect(defaults.data(forKey: key) == Data(
            repeating: 0x41,
            count: LogcatPersistenceState.maximumBlobBytes + 1
        ))

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
        let store = TestStore(initialState: LogcatFeature.State(
            filter: LogcatFilter(levels: [.error], query: "Window"),
            presetNameInput: "Errors"
        )) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.save = { _ in }
            $0.uuid = .constant(presetID)
        }

        await store.send(.savePreset) {
            let preset = LogcatPreset(
                id: presetID,
                name: "Errors",
                filterText: "Window",
                level: .error
            )
            $0.savedPresets = [preset]
            $0.allSavedPresets = [preset]
            $0.filtersByDeviceID[DeviceIdentity.unknownID] = LogcatFilterSettings(
                filterText: "Window",
                selectedLevel: .error
            )
            $0.presetNameInput = ""
            $0.appliedPresetID = presetID
        }

        let preset = try #require(store.state.savedPresets.first)
        #expect(store.state.savedPresets.count == 1)

        let warningPreset = LogcatPreset(name: "All Warnings", filterText: "Activity", level: .warning)
        await store.send(.applyPreset(warningPreset)) {
            $0.filterText = "Activity"
            $0.selectedLevel = .warning
            $0.filtersByDeviceID[DeviceIdentity.unknownID] = LogcatFilterSettings(
                filterText: "Activity",
                selectedLevel: .warning
            )
            $0.appliedPresetID = warningPreset.id
        }

        await store.send(.deletePreset(preset.id)) {
            $0.savedPresets = []
            $0.allSavedPresets = []
        }
    }

    @Test
    func duplicateRenameAndDeletePresetPreserveRichFilter() async throws {
        let originalID = UUID(1)
        let copyID = UUID(2)
        var original = LogcatPreset(
            id: originalID,
            name: "Process errors",
            filterText: "crash",
            level: nil,
            originDeviceID: "serial:pixel",
            includedTags: ["ActivityManager"],
            excludedTerms: ["heartbeat"],
            pid: 123
        )
        original.levels = [.error, .fatal]
        let store = TestStore(initialState: LogcatFeature.State(
            activeDeviceID: "serial:pixel",
            savedPresets: [original],
            allSavedPresets: [original]
        )) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.save = { _ in }
            $0.uuid = .constant(copyID)
        }
        store.exhaustivity = .off

        await store.send(.duplicatePreset(originalID))
        let copy = try #require(store.state.savedPresets.first(where: { $0.id == copyID }))
        #expect(copy.name == "Process errors Copy")
        #expect(copy.levels == [.error, .fatal])
        #expect(copy.includedTags == ["ActivityManager"])
        #expect(copy.excludedTerms == ["heartbeat"])
        #expect(copy.pid == 123)

        await store.send(.renamePreset(copyID, "Crash triage"))
        #expect(store.state.savedPresets.first(where: { $0.id == copyID })?.name == "Crash triage")

        await store.send(.deletePreset(originalID))
        #expect(store.state.savedPresets.map(\.id) == [copyID])
    }

    @Test
    func legacyPersistenceMigratesWithoutClaimingADevice() throws {
        struct LegacyPreset: Codable {
            var id: UUID
            var name: String
            var filterText: String
            var level: LogEntry.LogLevel?
        }
        struct LegacyState: Codable {
            var filterText: String
            var selectedLevel: LogEntry.LogLevel?
            var presets: [LegacyPreset]
        }

        let suiteName = "LogcatLegacyMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "logcat"
        let source = try JSONEncoder().encode(LegacyState(
            filterText: "ActivityManager",
            selectedLevel: .warning,
            presets: [LegacyPreset(
                id: UUID(0),
                name: "Legacy warnings",
                filterText: "",
                level: .warning
            )]
        ))
        defaults.set(source, forKey: key)

        let client = LogcatPersistenceClient.userDefaultsClient(defaults: defaults, key: key)
        let migrated = client.load()

        #expect(migrated.version == LogcatPersistenceState.currentVersion)
        #expect(migrated.filtersByDeviceID[DeviceIdentity.unknownID]?.filterText == "ActivityManager")
        #expect(migrated.presets.first?.originDeviceID == DeviceIdentity.unknownID)
        let rewritten = try #require(defaults.data(forKey: key))
        #expect(rewritten != source)
        #expect(try JSONDecoder().decode(LogcatPersistenceState.self, from: rewritten) == migrated)
    }

    @Test
    func v2PersistenceMigratesToRichFilterWithoutLosingScope() throws {
        struct V2Filter: Codable {
            var filterText: String
            var selectedLevel: LogEntry.LogLevel?
        }
        struct V2Preset: Codable {
            var id: UUID
            var name: String
            var filterText: String
            var level: LogEntry.LogLevel?
            var originDeviceID: String
        }
        struct V2State: Codable {
            var version: Int
            var filtersByDeviceID: [String: V2Filter]
            var presets: [V2Preset]
        }
        let deviceID = "guid:pixel"
        let presetID = UUID()
        let source = V2State(
            version: 2,
            filtersByDeviceID: [deviceID: V2Filter(filterText: "Activity", selectedLevel: .warning)],
            presets: [V2Preset(
                id: presetID,
                name: "Warnings",
                filterText: "Activity",
                level: .warning,
                originDeviceID: deviceID
            )]
        )

        let migrated = try #require(LogcatPersistenceState.decodeMigrating(JSONEncoder().encode(source)))
        let filter = try #require(migrated.state.filtersByDeviceID[deviceID])
        let preset = try #require(migrated.state.presets.first)

        #expect(migrated.wasLegacy)
        #expect(migrated.state.version == LogcatPersistenceState.currentVersion)
        #expect(filter.query == "Activity")
        #expect(filter.levels == [.warning])
        #expect(filter.includedTags.isEmpty)
        #expect(preset.id == presetID)
        #expect(preset.originDeviceID == deviceID)
        #expect(preset.levels == [.warning])
    }

    @Test
    func richFilterAndGlobalPresetRoundTrip() throws {
        var preset = LogcatPreset(
            name: "Process errors",
            filterText: "crash",
            level: nil,
            originDeviceID: "guid:pixel",
            includedTags: ["ActivityManager"],
            excludedTerms: ["heartbeat"],
            pid: 123,
            isGlobal: true
        )
        preset.levels = [.error, .fatal]
        let state = LogcatPersistenceState(
            filtersByDeviceID: [
                "guid:pixel": LogcatFilter(
                    levels: [.error, .fatal],
                    query: "crash",
                    includedTags: ["ActivityManager"],
                    excludedTerms: ["heartbeat"],
                    pid: 123
                )
            ],
            presets: [preset]
        )

        let data = try #require(state.encodedForPersistence())
        let decoded = try #require(LogcatPersistenceState.decodeMigrating(data)?.state)

        #expect(decoded == state.sanitized())
        #expect(decoded.presets.first?.isGlobal == true)
        #expect(decoded.presets.first?.levels == [.error, .fatal])
    }

    @Test
    func exportReviewFreezesScopeAndRedactsDeviceByDefault() async throws {
        let entries = (0..<3).map { index in
            LogEntry(
                timestamp: "00:00:0\(index)",
                pid: "1",
                tid: "2",
                level: .info,
                tag: "Tag",
                message: "message-\(index)"
            )
        }
        let store = TestStore(initialState: LogcatFeature.State(
            activeDeviceID: "serial:private-device",
            entries: entries,
            selectedEntryID: entries[1].id
        )) {
            LogcatFeature()
        }

        await store.send(.prepareExport(.fromSelection)) {
            $0.exportReview = LogcatExportReview(scope: .fromSelection, entries: Array(entries[1...]))
        }
        await store.send(.confirmExport) {
            $0.exportText = LogcatFeature.exportString(
                Array(entries[1...]),
                deviceID: "serial:private-device",
                includeDeviceMetadata: true,
                redactSensitiveValues: true
            )
            $0.exportReview = nil
        }
        let output = try #require(store.state.exportText)
        #expect(output.contains("message-1"))
        #expect(output.contains("message-2"))
        #expect(!output.contains("message-0"))
        #expect(output.contains("<redacted>"))
        #expect(!output.contains("private-device"))
    }

    @Test
    func deviceSwitchScopesFiltersAndPresets() async {
        let deviceA = "serial:a"
        let deviceB = "serial:b"
        let presetA = LogcatPreset(
            id: UUID(1),
            name: "A errors",
            filterText: "A",
            level: .error,
            originDeviceID: deviceA
        )
        let presetB = LogcatPreset(
            id: UUID(2),
            name: "B warnings",
            filterText: "B",
            level: .warning,
            originDeviceID: deviceB
        )
        let persisted = LogcatPersistenceState(
            filtersByDeviceID: [
                deviceA: LogcatFilterSettings(filterText: "A", selectedLevel: .error),
                deviceB: LogcatFilterSettings(filterText: "B", selectedLevel: .warning)
            ],
            presets: [presetA, presetB]
        )
        let store = TestStore(initialState: LogcatFeature.State(activeDeviceID: deviceA)) {
            LogcatFeature()
        } withDependencies: {
            $0.logcatPersistenceClient.load = { persisted }
            $0.logcatPersistenceClient.save = { _ in }
        }

        store.exhaustivity = .off
        await store.send(.loadPersistence)
        await store.receive(\.persistenceLoaded)
        store.exhaustivity = .on
        #expect(store.state.filterText == "A")
        #expect(store.state.savedPresets == [presetA])

        store.exhaustivity = .off
        await store.send(.setActiveDevice(deviceB))
        store.exhaustivity = .on
        #expect(store.state.filterText == "B")
        #expect(store.state.selectedLevel == .warning)
        #expect(store.state.savedPresets == [presetB])
    }

    @Test
    func logcatStopped() async {
        let store = TestStore(
            initialState: LogcatFeature.State(captureState: .live)
        ) {
            LogcatFeature()
        }

        await store.send(.logcatStopped) {
            $0.captureState = .stopped
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
            $0.captureState = .starting
            $0.captureGeneration = 1
            $0.activeCaptureGeneration = 1
            $0.entries = []
            $0.droppedCount = 0
            $0.followState = .following
            $0.errorMessage = nil
        }
        await store.receive(\.capturedFailed)
        await store.receive(\.logcatFailed) {
            $0.captureState = .failed(ADBError.notConnected.localizedDescription)
            $0.activeCaptureGeneration = nil
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
        await store.send(.dismissError) {
            $0.errorMessage = nil
        }
    }

    @Test
    func staleCaptureBatchCannotEnterNewCapture() async {
        let store = TestStore(initialState: LogcatFeature.State(
            captureState: .live,
            captureGeneration: 2,
            activeCaptureGeneration: 2
        )) {
            LogcatFeature()
        }
        let staleLine = "01-01 00:00:00.000  1000  1001 I Stale: old transport"

        await store.send(.capturedLines(generation: 1, [staleLine]))
        #expect(store.state.entries.isEmpty)
        #expect(store.state.activeCaptureGeneration == 2)
    }
}
