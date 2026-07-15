import Foundation
import ComposableArchitecture

enum FeedbackSeverity: Int, Equatable, Sendable {
    case information = 0
    case reconnecting = 1
    case operationFailure = 2
    case connectionError = 3
    case permissionDenied = 4
}

enum FeedbackRecovery: Equatable, Sendable {
    case reconnect
    case retryOperation(UUID)
    case openSettings
    case details(UUID)
}

enum UserFeedback: Equatable, Identifiable, Sendable {
    case banner(
        id: UUID,
        severity: FeedbackSeverity,
        message: String,
        recovery: FeedbackRecovery?
    )
    case toast(id: UUID, message: String, symbol: String)
    case validation(id: UUID, fieldID: String, message: String)

    var id: UUID {
        switch self {
        case .banner(let id, _, _, _), .toast(let id, _, _), .validation(let id, _, _): id
        }
    }

    var bannerSeverity: FeedbackSeverity? {
        guard case .banner(_, let severity, _, _) = self else { return nil }
        return severity
    }
}

@Reducer
struct FeedbackFeature {
    @ObservableState
    struct State: Equatable {
        var feedbackByWorkspace: [WorkspaceRoot: [UserFeedback]] = [:]
        var toast: UserFeedback?

        func banner(for workspace: WorkspaceRoot) -> UserFeedback? {
            feedbackByWorkspace[workspace]?
                .filter { $0.bannerSeverity != nil }
                .max { ($0.bannerSeverity?.rawValue ?? -1) < ($1.bannerSeverity?.rawValue ?? -1) }
        }
    }

    enum Action: Equatable {
        case present(workspace: WorkspaceRoot, UserFeedback)
        case dismiss(workspace: WorkspaceRoot, id: UUID)
        case showToast(id: UUID, message: String, symbol: String)
        case hideToast(id: UUID)
    }

    private enum CancelID { case toast }

    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .present(let workspace, let feedback):
                var items = state.feedbackByWorkspace[workspace] ?? []
                items.removeAll { $0.id == feedback.id }
                items.append(feedback)
                state.feedbackByWorkspace[workspace] = items
                return .none

            case .dismiss(let workspace, let id):
                state.feedbackByWorkspace[workspace]?.removeAll { $0.id == id }
                return .none

            case .showToast(let id, let message, let symbol):
                state.toast = .toast(id: id, message: message, symbol: symbol)
                return .run { send in
                    try await clock.sleep(for: .seconds(2))
                    await send(.hideToast(id: id))
                }
                .cancellable(id: CancelID.toast, cancelInFlight: true)

            case .hideToast(let id):
                guard state.toast?.id == id else { return .none }
                state.toast = nil
                return .none
            }
        }
    }
}
