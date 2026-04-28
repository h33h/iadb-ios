import Foundation
import ComposableArchitecture

@Reducer
struct LogcatFeature {
    @ObservableState
    struct State: Equatable {
        var entries: [LogEntry] = []
        var isRunning = false
        var filterText = ""
        var selectedLevel: LogEntry.LogLevel?
        var autoScroll = true
        var maxEntries = 5000
        var isPaused = false
        var pauseBuffer: [String] = []

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
        case startLogcat
        case stopLogcat
        case logcatLines([String])
        case logcatStopped
        case clearLog
        case togglePause
    }

    private enum CancelID { case logcat }

    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .startLogcat:
                guard !state.isRunning else { return .none }
                state.isRunning = true
                state.entries.removeAll()

                return .run { send in
                    let stream = try await adbClient.openLogcatStream()
                    var partialLine = ""

                    while !Task.isCancelled {
                        let message = try await stream.readMessage()
                        guard message.commandType == .write else {
                            if message.commandType == .close { break }
                            continue
                        }
                        try await stream.sendReady()

                        guard let text = message.dataString else { continue }
                        let fullText = partialLine + text
                        let lines = fullText.components(separatedBy: "\n")
                        partialLine = lines.last ?? ""
                        let completeLines = Array(lines.dropLast())
                        if !completeLines.isEmpty {
                            await send(.logcatLines(completeLines))
                        }
                    }

                    try? await stream.close()
                    await send(.logcatStopped)
                } catch: { _, send in
                    await send(.logcatStopped)
                }
                .cancellable(id: CancelID.logcat)

            case .stopLogcat:
                state.isRunning = false
                return .cancel(id: CancelID.logcat)

            case .logcatLines(let lines):
                if state.isPaused {
                    state.pauseBuffer.append(contentsOf: lines)
                    if state.pauseBuffer.count > state.maxEntries {
                        state.pauseBuffer.removeFirst(state.pauseBuffer.count - state.maxEntries)
                    }
                    return .none
                }
                let newEntries = lines.compactMap { LogEntry.parse($0) }
                state.entries.append(contentsOf: newEntries)
                if state.entries.count > state.maxEntries {
                    state.entries.removeFirst(state.entries.count - state.maxEntries)
                }
                return .none

            case .logcatStopped:
                state.isRunning = false
                return .none

            case .clearLog:
                state.entries.removeAll()
                return .none

            case .togglePause:
                state.isPaused.toggle()
                if !state.isPaused {
                    let buffered = state.pauseBuffer.compactMap { LogEntry.parse($0) }
                    state.entries.append(contentsOf: buffered)
                    state.pauseBuffer.removeAll()
                    if state.entries.count > state.maxEntries {
                        state.entries.removeFirst(state.entries.count - state.maxEntries)
                    }
                }
                return .none
            }
        }
    }
}
