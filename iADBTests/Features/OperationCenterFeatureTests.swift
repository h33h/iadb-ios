import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct OperationCenterFeatureTests {
    private let operationID = UUID(0)
    private let startedAt = Date(timeIntervalSince1970: 10)

    @Test
    func operationExistsBeforeProgressAndRejectsStaleCallbacks() async {
        let operation = makeOperation()
        let store = TestStore(initialState: OperationCenterFeature.State()) {
            OperationCenterFeature()
        }

        await store.send(.operationStarted(operation)) {
            $0.operations = [operation]
        }
        await store.send(.progress(id: UUID(1), completed: 50, total: 100))
        await store.send(.progress(id: operationID, completed: 25, total: 100)) {
            $0.operations[0].completedUnits = 25
            $0.operations[0].totalUnits = 100
        }
        let finishedAt = Date(timeIntervalSince1970: 20)
        await store.send(.operationFinished(
            id: operationID,
            outcome: .success(summary: "Saved"),
            date: finishedAt
        )) {
            $0.operations[0].phase = .finished
            $0.operations[0].outcome = .success(summary: "Saved")
            $0.operations[0].finishedAt = finishedAt
            $0.operations[0].isCancellable = false
        }
        await store.send(.progress(id: operationID, completed: 100, total: 100))
        #expect(store.state.operations[0].completedUnits == 25)
    }

    @Test
    func cancelPublishesCleanupAndKeepsFailureDetails() async {
        let finishedAt = Date(timeIntervalSince1970: 30)
        let store = TestStore(
            initialState: OperationCenterFeature.State(operations: [makeOperation()])
        ) {
            OperationCenterFeature()
        } withDependencies: {
            $0.date = .constant(finishedAt)
        }

        await store.send(.cancelTapped(operationID)) {
            $0.operations[0].phase = .cleaningUp
            $0.operations[0].detail = "Cancelling and cleaning up…"
            $0.operations[0].cleanupState = .pending
            $0.operations[0].isCancellable = false
        }
        await store.receive(\.delegate)
        await store.send(.cleanupCompleted(
            id: operationID,
            .failure(EquatableError(message: "temporary file remains"))
        )) {
            $0.operations[0].cleanupState = .failed("temporary file remains")
            $0.operations[0].phase = .finished
            $0.operations[0].outcome = .failure(
                message: "Cancelled, but cleanup failed: temporary file remains",
                retryable: false
            )
            $0.operations[0].finishedAt = finishedAt
        }
    }

    @Test
    func disconnectFinishesOnlyMatchingTransportOperations() async {
        var other = makeOperation(id: UUID(2))
        other.deviceID = "serial:other"
        let finishedAt = Date(timeIntervalSince1970: 40)
        let store = TestStore(initialState: OperationCenterFeature.State(
            operations: [makeOperation(), other]
        )) {
            OperationCenterFeature()
        }

        await store.send(.transportDisconnected(
            deviceID: "serial:test",
            message: "Wi-Fi changed",
            date: finishedAt
        )) {
            $0.operations[0].phase = .finished
            $0.operations[0].outcome = .failure(message: "Wi-Fi changed", retryable: true)
            $0.operations[0].detail = "Transport closed. Local cleanup completed."
            $0.operations[0].cleanupState = .succeeded
            $0.operations[0].isCancellable = false
            $0.operations[0].finishedAt = finishedAt
        }
        #expect(store.state.operations[1].isActive)
    }

    @Test
    func transportOperationsQueuePerDeviceAndPromoteInOrder() async {
        let first = makeOperation()
        var second = makeOperation(id: UUID(2))
        second.objectName = "Second transfer"
        let store = TestStore(initialState: OperationCenterFeature.State()) {
            OperationCenterFeature()
        }

        await store.send(.operationStarted(first)) {
            $0.operations = [first]
        }
        await store.send(.operationStarted(second)) {
            second.phase = .queued
            second.detail = "Waiting for the current device operation…"
            $0.operations = [second, first]
        }

        let finishedAt = Date(timeIntervalSince1970: 50)
        await store.send(.operationFinished(
            id: first.id,
            outcome: .success(summary: "Done"),
            date: finishedAt
        )) {
            $0.operations[1].phase = .finished
            $0.operations[1].outcome = .success(summary: "Done")
            $0.operations[1].finishedAt = finishedAt
            $0.operations[1].isCancellable = false
            $0.operations[0].phase = .preparing
            $0.operations[0].detail = "Starting on the target device…"
        }
    }

    private func makeOperation(id: UUID? = nil) -> BackgroundOperation {
        BackgroundOperation(
            id: id ?? operationID,
            deviceID: "serial:test",
            deviceName: "Pixel Test",
            workspace: .screens,
            kind: .capture,
            objectName: "Screenshot",
            phase: .running,
            completedUnits: nil,
            totalUnits: nil,
            detail: "Capturing…",
            isCancellable: true,
            isTransportDependent: true,
            cleanupState: .notRequired,
            outcome: nil,
            retryPayload: .captureScreenshot,
            startedAt: startedAt,
            finishedAt: nil
        )
    }
}

@MainActor
struct FeedbackFeatureTests {
    @Test
    func highestPriorityBannerWinsWithoutStacking() async {
        let infoID = UUID(0)
        let errorID = UUID(1)
        let store = TestStore(initialState: FeedbackFeature.State()) {
            FeedbackFeature()
        }

        await store.send(.present(
            workspace: .files,
            .banner(id: infoID, severity: .information, message: "Info", recovery: nil)
        )) {
            $0.feedbackByWorkspace[.files] = [
                .banner(id: infoID, severity: .information, message: "Info", recovery: nil)
            ]
        }
        await store.send(.present(
            workspace: .files,
            .banner(id: errorID, severity: .connectionError, message: "Offline", recovery: .reconnect)
        )) {
            $0.feedbackByWorkspace[.files]?.append(
                .banner(id: errorID, severity: .connectionError, message: "Offline", recovery: .reconnect)
            )
        }
        #expect(store.state.banner(for: .files)?.id == errorID)
    }

    @Test
    func toastAutoDismissesAndStaleTimerCannotHideNewToast() async {
        let firstID = UUID(0)
        let secondID = UUID(1)
        let store = TestStore(initialState: FeedbackFeature.State()) {
            FeedbackFeature()
        } withDependencies: {
            $0.continuousClock = ContinuousClock()
        }

        await store.send(.showToast(id: firstID, message: "Copied", symbol: "doc.on.doc")) {
            $0.toast = .toast(id: firstID, message: "Copied", symbol: "doc.on.doc")
        }
        await store.send(.showToast(id: secondID, message: "Saved", symbol: "checkmark")) {
            $0.toast = .toast(id: secondID, message: "Saved", symbol: "checkmark")
        }
        await store.receive(\.hideToast, timeout: .seconds(3)) {
            $0.toast = nil
        }
    }
}
