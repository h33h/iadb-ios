import Foundation
import ComposableArchitecture

enum WorkspaceRoot: String, Equatable, Hashable, Codable, CaseIterable, Sendable {
    case device
    case files
    case apps
    case console
    case screens
}

struct BackgroundOperation: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case upload
        case download
        case installAPK
        case fileMutation
        case appMutation
        case export
        case capture
    }

    enum Phase: Equatable, Sendable {
        case queued
        case preparing
        case running
        case cleaningUp
        case finished
    }

    enum Outcome: Equatable, Sendable {
        case success(summary: String)
        case failure(message: String, retryable: Bool)
        case cancelled
    }

    enum CleanupState: Equatable, Sendable {
        case notRequired
        case pending
        case succeeded
        case failed(String)
    }

    enum RetryPayload: Equatable, Sendable {
        case captureScreenshot
        case download(remotePath: String)
        case exportScreenshots(ids: [UUID])
    }

    var id: UUID
    var deviceID: String
    var deviceName: String
    var workspace: WorkspaceRoot
    var kind: Kind
    var objectName: String
    var phase: Phase
    var completedUnits: Int64?
    var totalUnits: Int64?
    var detail: String?
    var isCancellable: Bool
    var isTransportDependent: Bool
    var cleanupState: CleanupState
    var outcome: Outcome?
    var retryPayload: RetryPayload?
    var startedAt: Date
    var finishedAt: Date?

    var progressFraction: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else { return nil }
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }

    var isActive: Bool { phase != .finished }
    var canRetry: Bool {
        guard retryPayload != nil,
              case .failure(_, let retryable) = outcome else { return false }
        return retryable
    }
}

@Reducer
struct OperationCenterFeature {
    @Dependency(\.date) var date

    @ObservableState
    struct State: Equatable {
        var operations: [BackgroundOperation] = []
        var isPresented = false

        var activeOperations: [BackgroundOperation] {
            operations.filter(\.isActive)
        }

        var completedOperations: [BackgroundOperation] {
            operations.filter { !$0.isActive }
        }

        var activeCount: Int { activeOperations.count }
    }

    enum Action: Equatable {
        case setPresented(Bool)
        case operationStarted(BackgroundOperation)
        case operationPhase(id: UUID, phase: BackgroundOperation.Phase, detail: String?)
        case progress(id: UUID, completed: Int64, total: Int64?)
        case operationFinished(id: UUID, outcome: BackgroundOperation.Outcome, date: Date)
        case cancelTapped(UUID)
        case cleanupCompleted(id: UUID, Result<Bool, EquatableError>)
        case retryTapped(UUID)
        case transportDisconnected(deviceID: String, message: String, date: Date)
        case delegate(Delegate)

        enum Delegate: Equatable {
            case cancel(id: UUID, kind: BackgroundOperation.Kind)
            case retry(id: UUID, payload: BackgroundOperation.RetryPayload)
        }
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setPresented(let presented):
                state.isPresented = presented
                return .none

            case .operationStarted(let operation):
                guard !state.operations.contains(where: { $0.id == operation.id }) else { return .none }
                var operation = operation
                if operation.isTransportDependent,
                   state.operations.contains(where: {
                       $0.deviceID == operation.deviceID &&
                       $0.isTransportDependent &&
                       $0.isActive &&
                       $0.phase != .queued
                   }) {
                    operation.phase = .queued
                    operation.detail = String(localized: "Waiting for the current device operation…")
                }
                state.operations.insert(operation, at: 0)
                return .none

            case .operationPhase(let id, let phase, let detail):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].phase != .finished else { return .none }
                state.operations[index].phase = phase
                state.operations[index].detail = detail
                return .none

            case .progress(let id, let completed, let total):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].phase != .finished else { return .none }
                state.operations[index].completedUnits = max(0, completed)
                state.operations[index].totalUnits = total.map { max(0, $0) }
                return .none

            case .operationFinished(let id, let outcome, let date):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].phase != .finished else { return .none }
                state.operations[index].phase = .finished
                state.operations[index].outcome = outcome
                state.operations[index].finishedAt = date
                state.operations[index].isCancellable = false
                if state.operations[index].cleanupState == .pending {
                    state.operations[index].cleanupState = .succeeded
                }
                let deviceID = state.operations[index].deviceID
                promoteNextQueuedOperation(in: &state, deviceID: deviceID)
                return .none

            case .cancelTapped(let id):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].isActive,
                      state.operations[index].isCancellable else { return .none }
                let kind = state.operations[index].kind
                state.operations[index].phase = .cleaningUp
                state.operations[index].detail = String(localized: "Cancelling and cleaning up…")
                state.operations[index].cleanupState = .pending
                state.operations[index].isCancellable = false
                return .send(.delegate(.cancel(id: id, kind: kind)))

            case .cleanupCompleted(let id, .success(let didCleanUp)):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].phase != .finished else { return .none }
                state.operations[index].cleanupState = didCleanUp ? .succeeded : .notRequired
                state.operations[index].phase = .finished
                state.operations[index].outcome = .cancelled
                state.operations[index].finishedAt = date.now
                let deviceID = state.operations[index].deviceID
                promoteNextQueuedOperation(in: &state, deviceID: deviceID)
                return .none

            case .cleanupCompleted(let id, .failure(let error)):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].phase != .finished else { return .none }
                state.operations[index].cleanupState = .failed(error.message)
                state.operations[index].phase = .finished
                state.operations[index].outcome = .failure(
                    message: String(localized: "Cancelled, but cleanup failed: \(error.message)"),
                    retryable: false
                )
                state.operations[index].finishedAt = date.now
                let deviceID = state.operations[index].deviceID
                promoteNextQueuedOperation(in: &state, deviceID: deviceID)
                return .none

            case .retryTapped(let id):
                guard let index = state.operations.firstIndex(where: { $0.id == id }),
                      state.operations[index].canRetry,
                      let payload = state.operations[index].retryPayload else { return .none }
                return .send(.delegate(.retry(id: id, payload: payload)))

            case .transportDisconnected(let deviceID, let message, let date):
                for index in state.operations.indices where
                    state.operations[index].deviceID == deviceID &&
                    state.operations[index].isTransportDependent &&
                    state.operations[index].isActive {
                    state.operations[index].phase = .finished
                    state.operations[index].outcome = .failure(message: message, retryable: true)
                    state.operations[index].detail = String(localized: "Transport closed. Local cleanup completed.")
                    state.operations[index].cleanupState = .succeeded
                    state.operations[index].isCancellable = false
                    state.operations[index].finishedAt = date
                }
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func promoteNextQueuedOperation(in state: inout State, deviceID: String) {
        guard !state.operations.contains(where: {
            $0.deviceID == deviceID &&
            $0.isTransportDependent &&
            $0.isActive &&
            $0.phase != .queued
        }) else { return }
        guard let index = state.operations.lastIndex(where: {
            $0.deviceID == deviceID &&
            $0.isTransportDependent &&
            $0.phase == .queued
        }) else { return }
        state.operations[index].phase = .preparing
        state.operations[index].detail = String(localized: "Starting on the target device…")
    }

}

struct EquatableError: Error, Equatable, Sendable {
    var message: String

    init(_ error: any Error) {
        message = error.localizedDescription
    }

    init(message: String) {
        self.message = message
    }
}
