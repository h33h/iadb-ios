import Foundation
import ComposableArchitecture

struct LogcatChunkBuffer {
    var data = Data()
    var isDiscardingOversizedLine = false
}

func boundedLogcatLine(_ line: String, byteLimit: Int) -> String {
    guard line.utf8.count > byteLimit else { return line }
    return String(decoding: line.utf8.prefix(max(0, byteLimit)), as: UTF8.self)
        + " … [line truncated by iADB]"
}

func appendLogcatChunk(
    _ chunk: Data,
    to buffer: inout LogcatChunkBuffer,
    lineByteLimit: Int = LogcatFeature.maximumLineBytes
) -> [String] {
    buffer.data.append(chunk)
    var lines: [String] = []
    while let newlineIndex = buffer.data.firstIndex(of: 0x0A) {
        var lineData = Data(buffer.data[..<newlineIndex])
        buffer.data.removeSubrange(buffer.data.startIndex...newlineIndex)
        if lineData.last == 0x0D {
            lineData.removeLast()
        }
        let wasTruncated = buffer.isDiscardingOversizedLine || lineData.count > lineByteLimit
        let boundedData = lineData.prefix(max(0, lineByteLimit))
        var line = String(decoding: boundedData, as: UTF8.self)
        if wasTruncated { line += " … [line truncated by iADB]" }
        lines.append(line)
        buffer.isDiscardingOversizedLine = false
    }

    if buffer.data.count > lineByteLimit {
        buffer.data = Data(buffer.data.prefix(max(0, lineByteLimit)))
        buffer.isDiscardingOversizedLine = true
    }
    return lines
}

enum LogcatCaptureState: Equatable {
    case stopped
    case starting
    case live
    case failed(String)
}

enum LogcatFollowState: Equatable {
    case following
    case paused(newCount: Int)
}

enum LogcatExportScope: String, Equatable, CaseIterable {
    case filtered = "Current filtered view"
    case retained = "Full retained buffer"
    case fromSelection = "From selected line"

    var localizedTitle: String {
        switch self {
        case .filtered: String(localized: "Current filtered view")
        case .retained: String(localized: "Full retained buffer")
        case .fromSelection: String(localized: "From selected line")
        }
    }
}

struct LogcatExportReview: Equatable {
    var scope: LogcatExportScope
    var entries: [LogEntry]
    var includeDeviceMetadata = true
    var redactSensitiveValues = true
}

@Reducer
struct LogcatFeature {
    static let maximumLineBytes = 64 * 1024
    static let maximumRetainedBytes = 8 * 1024 * 1024

    @ObservableState
    struct State: Equatable {
        var activeDeviceID = DeviceIdentity.unknownID
        var entries: [LogEntry] = []
        var captureState: LogcatCaptureState = .stopped
        var followState: LogcatFollowState = .following
        var captureGeneration = 0
        var activeCaptureGeneration: Int?
        var filter = LogcatFilter.empty
        var savedPresets: [LogcatPreset] = []
        var allSavedPresets: [LogcatPreset] = []
        var filtersByDeviceID: [String: LogcatFilterSettings] = [:]
        var didLoadPersistence = false
        var presetNameInput = ""
        var newPresetIsGlobal = false
        var appliedPresetID: UUID?
        var exportText: String?
        var exportReview: LogcatExportReview?
        var selectedEntryID: UUID?
        var bookmarkedEntryIDs: Set<UUID> = []
        var showsProcessColumn = true
        var maxEntries = 5000
        var maxRetainedBytes = LogcatFeature.maximumRetainedBytes
        var maxLineBytes = LogcatFeature.maximumLineBytes
        var droppedCount = 0
        var errorMessage: String?

        var filterText: String {
            get { filter.query }
            set { filter.query = newValue }
        }

        var selectedLevel: LogEntry.LogLevel? {
            get { filter.selectedLevel }
            set { filter.selectedLevel = newValue }
        }

        var isRunning: Bool {
            switch captureState {
            case .starting, .live: true
            case .stopped, .failed: false
            }
        }

        var isPaused: Bool {
            if case .paused = followState { true } else { false }
        }

        var newEntryCount: Int {
            if case .paused(let count) = followState { count } else { 0 }
        }

        var autoScroll: Bool {
            get { followState == .following }
            set { followState = newValue ? .following : .paused(newCount: 0) }
        }

        var retainedBytes: Int {
            entries.reduce(0) { $0 + LogcatFeature.serializedLine($1).utf8.count + 1 }
        }

        var hasUnsavedFilter: Bool {
            guard let appliedPresetID,
                  let preset = savedPresets.first(where: { $0.id == appliedPresetID }) else {
                return !filter.query.isEmpty || !filter.levels.isEmpty ||
                    !filter.includedTags.isEmpty || !filter.excludedTerms.isEmpty || filter.pid != nil
            }
            return filter.query != preset.filterText || filter.levels != preset.levels ||
                filter.includedTags != preset.includedTags ||
                filter.excludedTerms != preset.excludedTerms || filter.pid != preset.pid
        }

        var filteredEntries: [LogEntry] {
            var result = entries
            if !filter.levels.isEmpty {
                result = result.filter { filter.levels.contains($0.level) }
            }
            if !filter.query.isEmpty {
                result = result.filter {
                    $0.tag.localizedCaseInsensitiveContains(filter.query) ||
                    $0.message.localizedCaseInsensitiveContains(filter.query)
                }
            }
            if !filter.includedTags.isEmpty {
                result = result.filter { entry in
                    filter.includedTags.contains { entry.tag.localizedCaseInsensitiveCompare($0) == .orderedSame }
                }
            }
            if !filter.excludedTerms.isEmpty {
                result = result.filter { entry in
                    !filter.excludedTerms.contains { term in
                        entry.tag.localizedCaseInsensitiveContains(term) ||
                            entry.message.localizedCaseInsensitiveContains(term)
                    }
                }
            }
            if let pid = filter.pid {
                result = result.filter { Int($0.pid) == pid }
            }
            return result
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setActiveDevice(String?)
        case onAppear
        case startLogcat
        case stopLogcat
        case captureStarted(generation: Int)
        case capturedLines(generation: Int, [String])
        case capturedStopped(generation: Int)
        case capturedFailed(generation: Int, String)
        case logcatLines([String])
        case logcatStopped
        case logcatFailed(String)
        case dismissError
        case clearLog
        case togglePause
        case loadPersistence
        case persistenceLoaded(LogcatPersistenceState)
        case savePreset
        case applyPreset(LogcatPreset)
        case duplicatePreset(UUID)
        case renamePreset(UUID, String)
        case deletePreset(UUID)
        case selectEntry(UUID?)
        case toggleBookmark(UUID)
        case prepareExport(LogcatExportScope)
        case setExportOptions(includeDeviceMetadata: Bool, redactSensitiveValues: Bool)
        case confirmExport
        case cancelExport
        case clearExport
    }

    private enum CancelID { case logcat }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.logcatPersistenceClient) var logcatPersistenceClient
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.didLoadPersistence else { return .none }
                return .send(.loadPersistence)

            case .binding:
                synchronizeActiveWorkspace(in: &state)
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .setActiveDevice(let deviceID):
                synchronizeActiveWorkspace(in: &state)
                state.activeDeviceID = deviceID ?? DeviceIdentity.unknownID
                state.appliedPresetID = nil
                state.selectedEntryID = nil
                state.exportReview = nil
                applyActiveWorkspace(to: &state)
                persist(state)
                return .none

            case .loadPersistence:
                state.didLoadPersistence = true
                return .run { send in
                    await send(.persistenceLoaded(logcatPersistenceClient.load()))
                }

            case .persistenceLoaded(let persisted):
                let persisted = persisted.sanitized()
                state.filtersByDeviceID = persisted.filtersByDeviceID
                state.allSavedPresets = persisted.presets
                applyActiveWorkspace(to: &state)
                return .none

            case .startLogcat:
                guard !state.isRunning else { return .none }
                state.captureState = .starting
                state.captureGeneration += 1
                let generation = state.captureGeneration
                state.activeCaptureGeneration = generation
                state.entries.removeAll()
                state.droppedCount = 0
                state.followState = .following
                state.errorMessage = nil
                PerformanceSignposts.logBatch("capture-start")

                return .run { send in
                    let stream = try await adbClient.openLogcatStream()
                    await send(.captureStarted(generation: generation))
                    var partialLine = LogcatChunkBuffer()
                    var pendingLines: [String] = []
                    let clock = ContinuousClock()
                    var lastEmission = clock.now

                    while !Task.isCancelled {
                        let message = try await stream.readMessage()
                        guard message.commandType == .write else {
                            if message.commandType == .close {
                                if !partialLine.data.isEmpty {
                                    var finalLine = String(decoding: partialLine.data, as: UTF8.self)
                                    if partialLine.isDiscardingOversizedLine {
                                        finalLine += " … [line truncated by iADB]"
                                    }
                                    pendingLines.append(finalLine)
                                }
                                break
                            }
                            continue
                        }
                        try await stream.sendReady()

                        let completeLines = appendLogcatChunk(
                            message.data,
                            to: &partialLine,
                            lineByteLimit: Self.maximumLineBytes
                        )
                        if !completeLines.isEmpty {
                            pendingLines.append(contentsOf: completeLines)
                        }
                        if pendingLines.count >= 256 || clock.now - lastEmission >= .milliseconds(125) {
                            await send(.capturedLines(generation: generation, pendingLines))
                            pendingLines.removeAll(keepingCapacity: true)
                            lastEmission = clock.now
                        }
                    }

                    if !pendingLines.isEmpty {
                        await send(.capturedLines(generation: generation, pendingLines))
                    }

                    try? await stream.close()
                    await send(.capturedStopped(generation: generation))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.capturedFailed(
                        generation: generation,
                        error.localizedDescription
                    ))
                }
                .cancellable(id: CancelID.logcat, cancelInFlight: true)

            case .stopLogcat:
                state.captureState = .stopped
                state.activeCaptureGeneration = nil
                return .cancel(id: CancelID.logcat)

            case .captureStarted(let generation):
                guard state.activeCaptureGeneration == generation else { return .none }
                state.captureState = .live
                return .none

            case .capturedLines(let generation, let lines):
                guard state.activeCaptureGeneration == generation else { return .none }
                return .send(.logcatLines(lines))

            case .capturedStopped(let generation):
                guard state.activeCaptureGeneration == generation else { return .none }
                return .send(.logcatStopped)

            case .capturedFailed(let generation, let message):
                guard state.activeCaptureGeneration == generation else { return .none }
                return .send(.logcatFailed(message))

            case .logcatLines(let lines):
                PerformanceSignposts.logBatch("received", lineCount: lines.count)
                let boundedLines = lines.map { boundedLogcatLine($0, byteLimit: state.maxLineBytes) }
                let newEntries = boundedLines.compactMap { LogEntry.parse($0) }
                let result = Self.appendingToRing(
                    newEntries,
                    existing: state.entries,
                    countLimit: state.maxEntries,
                    byteLimit: state.maxRetainedBytes
                )
                state.entries = result.entries
                state.droppedCount += result.dropped
                if case .paused(let count) = state.followState {
                    state.followState = .paused(newCount: count + newEntries.count)
                }
                return .none

            case .logcatStopped:
                state.captureState = .stopped
                state.activeCaptureGeneration = nil
                PerformanceSignposts.logBatch("capture-stopped")
                return .none

            case .logcatFailed(let message):
                state.captureState = .failed(message)
                state.activeCaptureGeneration = nil
                state.errorMessage = message
                PerformanceSignposts.logBatch("capture-failed")
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none

            case .clearLog:
                state.entries.removeAll()
                state.droppedCount = 0
                if state.isPaused { state.followState = .paused(newCount: 0) }
                return .none

            case .togglePause:
                switch state.followState {
                case .following:
                    state.followState = .paused(newCount: 0)
                case .paused:
                    state.followState = .following
                }
                return .none

            case .savePreset:
                let trimmedName = LogcatPersistenceState.boundedText(state.presetNameInput)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filterText = LogcatPersistenceState.boundedText(state.filterText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return .none }
                var preset = LogcatPreset(
                    id: uuid(),
                    name: trimmedName,
                    filterText: filterText,
                    level: state.selectedLevel,
                    originDeviceID: state.newPresetIsGlobal ? "global" : state.activeDeviceID,
                    includedTags: state.filter.includedTags,
                    excludedTerms: state.filter.excludedTerms,
                    pid: state.filter.pid,
                    isGlobal: state.newPresetIsGlobal
                )
                preset.levels = state.filter.levels
                state.savedPresets.insert(preset, at: 0)
                state.appliedPresetID = preset.id
                state.presetNameInput = ""
                state.newPresetIsGlobal = false
                synchronizeActiveWorkspace(in: &state)
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .applyPreset(let preset):
                state.filterText = LogcatPersistenceState.boundedText(preset.filterText)
                state.filter.levels = preset.levels
                state.filter.includedTags = preset.includedTags
                state.filter.excludedTerms = preset.excludedTerms
                state.filter.pid = preset.pid
                state.appliedPresetID = preset.id
                synchronizeActiveWorkspace(in: &state)
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .duplicatePreset(let id):
                guard var preset = state.savedPresets.first(where: { $0.id == id }) else {
                    return .none
                }
                preset.id = uuid()
                preset.name = LogcatPersistenceState.boundedText(preset.name + " Copy")
                state.savedPresets.insert(preset, at: 0)
                synchronizeActiveWorkspace(in: &state)
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .renamePreset(let id, let rawName):
                let name = LogcatPersistenceState.boundedText(rawName)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      let index = state.savedPresets.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                state.savedPresets[index].name = name
                synchronizeActiveWorkspace(in: &state)
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .deletePreset(let id):
                state.savedPresets.removeAll { $0.id == id }
                if state.appliedPresetID == id { state.appliedPresetID = nil }
                synchronizeActiveWorkspace(in: &state)
                persist(state)
                return .none

            case .selectEntry(let id):
                state.selectedEntryID = id
                return .none

            case .toggleBookmark(let id):
                if !state.bookmarkedEntryIDs.insert(id).inserted {
                    state.bookmarkedEntryIDs.remove(id)
                }
                return .none

            case .prepareExport(let scope):
                let entries: [LogEntry]
                switch scope {
                case .filtered:
                    entries = state.filteredEntries
                case .retained:
                    entries = state.entries
                case .fromSelection:
                    guard let selectedEntryID = state.selectedEntryID,
                          let index = state.entries.firstIndex(where: { $0.id == selectedEntryID }) else {
                        return .none
                    }
                    entries = Array(state.entries[index...])
                }
                state.exportReview = LogcatExportReview(scope: scope, entries: entries)
                return .none

            case .setExportOptions(let includeMetadata, let redact):
                state.exportReview?.includeDeviceMetadata = includeMetadata
                state.exportReview?.redactSensitiveValues = redact
                return .none

            case .confirmExport:
                guard let review = state.exportReview else { return .none }
                state.exportText = Self.exportString(
                    review.entries,
                    deviceID: state.activeDeviceID,
                    includeDeviceMetadata: review.includeDeviceMetadata,
                    redactSensitiveValues: review.redactSensitiveValues
                )
                state.exportReview = nil
                return .none

            case .cancelExport:
                state.exportReview = nil
                return .none

            case .clearExport:
                state.exportText = nil
                return .none
            }
        }
    }

    private func persist(_ state: State) {
        logcatPersistenceClient.save(persistenceState(from: state).sanitized())
    }

    private func sanitizePersistenceState(_ state: inout State) {
        let sanitized = persistenceState(from: state).sanitized()
        state.filtersByDeviceID = sanitized.filtersByDeviceID
        state.allSavedPresets = sanitized.presets
        applyActiveWorkspace(to: &state)
        state.presetNameInput = LogcatPersistenceState.boundedText(state.presetNameInput)
    }

    private func persistenceState(from state: State) -> LogcatPersistenceState {
        LogcatPersistenceState(
            filtersByDeviceID: state.filtersByDeviceID,
            presets: state.allSavedPresets
        )
    }

    private func applyActiveWorkspace(to state: inout State) {
        let settings = state.filtersByDeviceID[state.activeDeviceID] ?? .empty
        state.filter = settings
        state.savedPresets = state.allSavedPresets.filter {
            $0.originDeviceID == state.activeDeviceID || $0.isGlobal
        }
    }

    private func synchronizeActiveWorkspace(in state: inout State) {
        let activeDeviceID = state.activeDeviceID
        state.filtersByDeviceID[activeDeviceID] = state.filter
        state.allSavedPresets.removeAll { $0.originDeviceID == activeDeviceID || $0.isGlobal }
        state.allSavedPresets.append(contentsOf: state.savedPresets.map {
            var preset = LogcatPreset(
                id: $0.id,
                name: $0.name,
                filterText: $0.filterText,
                level: $0.level,
                originDeviceID: $0.isGlobal ? $0.originDeviceID : activeDeviceID,
                includedTags: $0.includedTags,
                excludedTerms: $0.excludedTerms,
                pid: $0.pid,
                isGlobal: $0.isGlobal
            )
            preset.levels = $0.levels
            return preset
        })
    }

    static func retainedLines(_ lines: [String], countLimit: Int, byteLimit: Int) -> [String] {
        var retained: [String] = []
        var bytes = 0
        for line in lines.reversed() where retained.count < max(0, countLimit) {
            let lineBytes = line.utf8.count + 1
            guard lineBytes <= byteLimit - bytes else { continue }
            retained.append(line)
            bytes += lineBytes
        }
        return Array(retained.reversed())
    }

    static func retainedEntries(_ entries: [LogEntry], countLimit: Int, byteLimit: Int) -> [LogEntry] {
        var retained: [LogEntry] = []
        var bytes = 0
        for entry in entries.reversed() where retained.count < max(0, countLimit) {
            let entryBytes = serializedLine(entry).utf8.count + 1
            guard entryBytes <= byteLimit - bytes else { break }
            retained.append(entry)
            bytes += entryBytes
        }
        return Array(retained.reversed())
    }

    static func appendingToRing(
        _ newEntries: [LogEntry],
        existing: [LogEntry],
        countLimit: Int,
        byteLimit: Int
    ) -> (entries: [LogEntry], dropped: Int) {
        let combined = existing + newEntries
        let retained = retainedEntries(
            combined,
            countLimit: countLimit,
            byteLimit: byteLimit
        )
        return (retained, max(0, combined.count - retained.count))
    }

    static func serializedLine(_ entry: LogEntry) -> String {
        "\(entry.timestamp) \(entry.pid) \(entry.tid) \(entry.level.rawValue) \(entry.tag): \(entry.message)"
    }

    static func exportString(_ entries: [LogEntry], byteLimit: Int = maximumRetainedBytes) -> String {
        exportString(
            entries,
            deviceID: nil,
            includeDeviceMetadata: false,
            redactSensitiveValues: true,
            byteLimit: byteLimit
        )
    }

    static func exportString(
        _ entries: [LogEntry],
        deviceID: String?,
        includeDeviceMetadata: Bool,
        redactSensitiveValues: Bool,
        byteLimit: Int = maximumRetainedBytes
    ) -> String {
        var data = Data()
        if includeDeviceMetadata, let deviceID {
            let value = redactSensitiveValues ? "<redacted>" : deviceID
            data.append(Data("# iADB Logcat\n# Device: \(value)\n".utf8))
        }
        for entry in entries {
            let separator = data.isEmpty || data.last == 0x0A ? "" : "\n"
            let lineData = Data((separator + serializedLine(entry)).utf8)
            guard lineData.count <= byteLimit - data.count else { break }
            data.append(lineData)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
