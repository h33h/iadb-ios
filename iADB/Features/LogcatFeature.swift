import ComposableArchitecture
import Foundation

@Reducer
struct LogcatFeature {
    @ObservableState
    struct State: Equatable {
        var entries: [LogEntry] = []
        var isConnected = false
        var isCapturing = false
        var errorMessage: String?
    }

    enum Action {
        case setConnected(Bool)
        case start
        case received([LogEntry])
        case failed(Error)
        case stop
        case clear
    }

    private enum CancelID { case stream }
    private static let entryLimit = 5_000
    @Dependency(\.adbClient) var adbClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setConnected(let value):
                state.isConnected = value
                return value ? .none : .send(.stop)

            case .start:
                guard state.isConnected, !state.isCapturing else { return .none }
                state.isCapturing = true
                state.errorMessage = nil
                return .run { send in
                    let stream = try await adbClient.openLogcatStream()
                    var pending = Data()
                    do {
                        while !Task.isCancelled {
                            let message = try await stream.readMessage()
                            switch message.commandType {
                            case .write:
                                pending.append(message.data)
                                try await stream.sendReady()
                                let parsed = Self.consumeLines(from: &pending)
                                if !parsed.isEmpty { await send(.received(parsed)) }
                            case .close:
                                await stream.acknowledgeRemoteClose()
                                return
                            default:
                                continue
                            }
                        }
                    } catch is CancellationError {
                        try? await stream.close()
                    } catch {
                        try? await stream.close()
                        await send(.failed(error))
                    }
                } catch: { error, send in
                    await send(.failed(error))
                }
                .cancellable(id: CancelID.stream, cancelInFlight: true)

            case .received(let entries):
                state.entries.append(contentsOf: entries)
                if state.entries.count > Self.entryLimit {
                    state.entries.removeFirst(state.entries.count - Self.entryLimit)
                }
                return .none

            case .failed(let error):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .stop:
                state.isCapturing = false
                return .cancel(id: CancelID.stream)

            case .clear:
                state.entries = []
                return .none
            }
        }
    }

    static func consumeLines(from data: inout Data) -> [LogEntry] {
        var entries: [LogEntry] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[..<newline]
            data.removeSubrange(...newline)
            if let entry = LogEntry.parse(String(decoding: lineData, as: UTF8.self)) {
                entries.append(entry)
            }
        }
        return entries
    }
}
