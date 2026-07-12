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

@Reducer
struct LogcatFeature {
    static let maximumLineBytes = 64 * 1024
    static let maximumRetainedBytes = 8 * 1024 * 1024

    @ObservableState
    struct State: Equatable {
        var entries: [LogEntry] = []
        var isRunning = false
        var filterText = ""
        var selectedLevel: LogEntry.LogLevel?
        var savedPresets: [LogcatPreset] = []
        var didLoadPersistence = false
        var presetNameInput = ""
        var exportText: String?
        var autoScroll = true
        var maxEntries = 5000
        var maxRetainedBytes = LogcatFeature.maximumRetainedBytes
        var maxLineBytes = LogcatFeature.maximumLineBytes
        var isPaused = false
        var pauseBuffer: [String] = []
        var errorMessage: String?

        var filteredEntries: [LogEntry] {
            var result = entries
            if let level = selectedLevel {
                result = result.filter { $0.level == level }
            }
            if !filterText.isEmpty {
                result = result.filter {
                    $0.tag.localizedCaseInsensitiveContains(filterText) ||
                    $0.message.localizedCaseInsensitiveContains(filterText)
                }
            }
            return result
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case startLogcat
        case stopLogcat
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
        case deletePreset(UUID)
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
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .loadPersistence:
                state.didLoadPersistence = true
                return .run { send in
                    await send(.persistenceLoaded(logcatPersistenceClient.load()))
                }

            case .persistenceLoaded(let persisted):
                let persisted = persisted.sanitized()
                state.filterText = persisted.filterText
                state.selectedLevel = persisted.selectedLevel
                state.savedPresets = persisted.presets
                return .none

            case .startLogcat:
                guard !state.isRunning else { return .none }
                state.isRunning = true
                state.entries.removeAll()
                state.pauseBuffer.removeAll()
                state.isPaused = false
                state.errorMessage = nil

                return .run { send in
                    let stream = try await adbClient.openLogcatStream()
                    var partialLine = LogcatChunkBuffer()

                    while !Task.isCancelled {
                        let message = try await stream.readMessage()
                        guard message.commandType == .write else {
                            if message.commandType == .close {
                                if !partialLine.data.isEmpty {
                                    var finalLine = String(decoding: partialLine.data, as: UTF8.self)
                                    if partialLine.isDiscardingOversizedLine {
                                        finalLine += " … [line truncated by iADB]"
                                    }
                                    await send(.logcatLines([finalLine]))
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
                            await send(.logcatLines(completeLines))
                        }
                    }

                    try? await stream.close()
                    await send(.logcatStopped)
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.logcatFailed(error.localizedDescription))
                }
                .cancellable(id: CancelID.logcat, cancelInFlight: true)

            case .stopLogcat:
                state.isRunning = false
                state.isPaused = false
                state.pauseBuffer.removeAll()
                return .cancel(id: CancelID.logcat)

            case .logcatLines(let lines):
                let boundedLines = lines.map { boundedLogcatLine($0, byteLimit: state.maxLineBytes) }
                if state.isPaused {
                    state.pauseBuffer.append(contentsOf: boundedLines)
                    state.pauseBuffer = Self.retainedLines(
                        state.pauseBuffer,
                        countLimit: state.maxEntries,
                        byteLimit: state.maxRetainedBytes
                    )
                    return .none
                }
                let newEntries = boundedLines.compactMap { LogEntry.parse($0) }
                state.entries.append(contentsOf: newEntries)
                state.entries = Self.retainedEntries(
                    state.entries,
                    countLimit: state.maxEntries,
                    byteLimit: state.maxRetainedBytes
                )
                return .none

            case .logcatStopped:
                state.isRunning = false
                state.isPaused = false
                state.pauseBuffer.removeAll()
                return .none

            case .logcatFailed(let message):
                state.isRunning = false
                state.isPaused = false
                state.pauseBuffer.removeAll()
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none

            case .clearLog:
                state.entries.removeAll()
                state.pauseBuffer.removeAll()
                return .none

            case .togglePause:
                state.isPaused.toggle()
                if !state.isPaused {
                    let buffered = state.pauseBuffer.compactMap { LogEntry.parse($0) }
                    state.entries.append(contentsOf: buffered)
                    state.pauseBuffer.removeAll()
                    state.entries = Self.retainedEntries(
                        state.entries,
                        countLimit: state.maxEntries,
                        byteLimit: state.maxRetainedBytes
                    )
                }
                return .none

            case .savePreset:
                let trimmedName = LogcatPersistenceState.boundedText(state.presetNameInput)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filterText = LogcatPersistenceState.boundedText(state.filterText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return .none }
                let preset = LogcatPreset(id: uuid(), name: trimmedName, filterText: filterText, level: state.selectedLevel)
                state.savedPresets.insert(preset, at: 0)
                state.presetNameInput = ""
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .applyPreset(let preset):
                state.filterText = LogcatPersistenceState.boundedText(preset.filterText)
                state.selectedLevel = preset.level
                sanitizePersistenceState(&state)
                persist(state)
                return .none

            case .deletePreset(let id):
                state.savedPresets.removeAll { $0.id == id }
                persist(state)
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
        state.filterText = sanitized.filterText
        state.selectedLevel = sanitized.selectedLevel
        state.savedPresets = sanitized.presets
        state.presetNameInput = LogcatPersistenceState.boundedText(state.presetNameInput)
    }

    private func persistenceState(from state: State) -> LogcatPersistenceState {
        LogcatPersistenceState(
            filterText: state.filterText,
            selectedLevel: state.selectedLevel,
            presets: state.savedPresets
        )
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
            guard entryBytes <= byteLimit - bytes else { continue }
            retained.append(entry)
            bytes += entryBytes
        }
        return Array(retained.reversed())
    }

    static func serializedLine(_ entry: LogEntry) -> String {
        "\(entry.timestamp) \(entry.pid) \(entry.tid) \(entry.level.rawValue) \(entry.tag): \(entry.message)"
    }

    static func exportString(_ entries: [LogEntry], byteLimit: Int = maximumRetainedBytes) -> String {
        var data = Data()
        for entry in entries {
            let separator = data.isEmpty ? "" : "\n"
            let lineData = Data((separator + serializedLine(entry)).utf8)
            guard lineData.count <= byteLimit - data.count else { break }
            data.append(lineData)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
