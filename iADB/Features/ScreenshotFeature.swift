import Foundation
import UIKit
import ComposableArchitecture

enum ScreenshotSortOrder: String, CaseIterable, Codable, Equatable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }
    var title: String {
        self == .newestFirst ? String(localized: "Newest first") : String(localized: "Oldest first")
    }
}

enum ScreenshotGrouping: String, CaseIterable, Codable, Equatable, Identifiable {
    case day
    case device

    var id: String { rawValue }
    var title: String {
        self == .day ? String(localized: "Day") : String(localized: "Device")
    }
}

struct ScreenshotBulkResult: Equatable, Identifiable {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    var id: UUID
    var fileName: String
    var outcome: Outcome
}

struct ScreenshotRetentionReview: Equatable {
    var proposedPolicy: ScreenshotRetentionPolicy
    var evictedScreenshotIDs: [UUID]
    var reclaimedByteCount: Int
}

@Reducer
struct ScreenshotFeature {
    enum ExportDestination: String, Equatable {
        case share = "Share"
        case photos = "Photos"
    }

    enum ErrorRecovery: Equatable {
        case capture
        case load
        case clear
    }

    struct ScreenshotEntry: Equatable, Identifiable {
        let id: UUID
        let timestamp: Date
        let data: Data
        let originDeviceID: String
        let originDeviceName: String?
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        var note: String?

        init(
            id: UUID,
            timestamp: Date,
            data: Data,
            originDeviceID: String = DeviceIdentity.unknownID,
            originDeviceName: String? = nil,
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            byteCount: Int? = nil,
            note: String? = nil
        ) {
            let needsWidth = pixelWidth.map { $0 <= 0 } ?? true
            let needsHeight = pixelHeight.map { $0 <= 0 } ?? true
            let image = needsWidth || needsHeight ? UIImage(data: data) : nil
            self.id = id
            self.timestamp = timestamp
            self.data = data
            self.originDeviceID = originDeviceID
            self.originDeviceName = originDeviceName
            self.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
                ?? image.map { Int($0.size.width * $0.scale) } ?? 0
            self.pixelHeight = pixelHeight.flatMap { $0 > 0 ? $0 : nil }
                ?? image.map { Int($0.size.height * $0.scale) } ?? 0
            self.byteCount = byteCount.flatMap { $0 > 0 ? $0 : nil } ?? data.count
            self.note = note
        }

        var fileName: String { "\(id.uuidString).png" }
    }

    @ObservableState
    struct State: Equatable {
        var activeDeviceID = DeviceIdentity.unknownID
        var activeDeviceName: String?
        var screenshots: [ScreenshotEntry] = []
        var isCapturing = false
        var captureGeneration = 0
        var activeCaptureGeneration: Int?
        var activeCaptureOperationID: UUID?
        var activeExports: [UUID: ExportDestination] = [:]
        var errorMessage: String?
        var selectedScreenshot: ScreenshotEntry?
        var didLoadPersistence = false
        var isLoadingPersistence = false
        var persistenceLoadGeneration = 0
        var errorRecovery: ErrorRecovery?
        var isPersisting = false
        var isClearing = false
        var pendingPersistenceRollback: [ScreenshotEntry]?
        var pendingSelectedScreenshotRollback: ScreenshotEntry?
        var retentionPolicy: ScreenshotRetentionPolicy = .unlimited
        var pendingRetentionPolicyRollback: ScreenshotRetentionPolicy?
        var pendingRetentionPolicySave: ScreenshotRetentionPolicy?
        var retentionReview: ScreenshotRetentionReview?
        var isSelecting = false
        var selectedScreenshotIDs: Set<UUID> = []
        var sortOrder: ScreenshotSortOrder = .newestFirst
        var grouping: ScreenshotGrouping = .day
        var viewerScreenshotID: UUID?
        var comparisonScreenshotIDs: [UUID] = []
        var bulkResults: [ScreenshotBulkResult] = []
        var pendingBulkDeleteItems: [ScreenshotBulkResult] = []
        var pendingBulkPreflightResults: [ScreenshotBulkResult] = []
        var pendingSelectedScreenshotIDsRollback: Set<UUID>?
        var pendingIsSelectingRollback: Bool?
        var pendingViewerScreenshotIDRollback: UUID?
        var pendingComparisonScreenshotIDsRollback: [UUID]?
        var isBulkDeleteConfirmationPresented = false

        var storageByteCount: Int { screenshots.reduce(0) { $0 + $1.data.count } }

        var sortedScreenshots: [ScreenshotEntry] {
            screenshots.sorted {
                sortOrder == .newestFirst ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp
            }
        }

        var selectedScreenshots: [ScreenshotEntry] {
            sortedScreenshots.filter { selectedScreenshotIDs.contains($0.id) }
        }

        var viewerScreenshot: ScreenshotEntry? {
            viewerScreenshotID.flatMap { id in screenshots.first { $0.id == id } }
        }

        var comparisonScreenshots: [ScreenshotEntry] {
            comparisonScreenshotIDs.compactMap { id in screenshots.first { $0.id == id } }
        }

        var canCompareSelection: Bool {
            let entries = selectedScreenshots
            guard entries.count == 2,
                  let first = entries.first,
                  let second = entries.last else { return false }
            return first.pixelWidth > 0 && first.pixelHeight > 0 &&
                first.pixelWidth == second.pixelWidth && first.pixelHeight == second.pixelHeight
        }
    }

    enum Action {
        case setActiveDevice(DeviceIdentity?)
        case onAppear
        case takeScreenshot
        case cancelCapture
        case cancelAll
        case captureResponse(generation: Int, deviceID: String, Result<Data, Error>)
        case screenshotCaptured(Result<Data, Error>)
        case deleteScreenshot(ScreenshotEntry)
        case selectScreenshot(ScreenshotEntry?)
        case setSelectionMode(Bool)
        case toggleSelection(UUID)
        case selectAll
        case setSortOrder(ScreenshotSortOrder)
        case setGrouping(ScreenshotGrouping)
        case openViewer(UUID)
        case closeViewer
        case openComparison
        case closeComparison
        case saveNote(UUID, String)
        case bulkDeleteSelected
        case requestBulkDelete
        case confirmBulkDelete
        case cancelBulkDelete
        case dismissBulkResults
        case clearAll
        case loadPersistence
        case persistenceLoaded(generation: Int, ScreenshotPersistenceBundle)
        case persistenceLoadFailed(generation: Int, String)
        case persistenceSucceeded
        case persistenceFailed(String)
        case clearCompleted(Result<Void, Error>)
        case setRetentionPolicy(ScreenshotRetentionPolicy)
        case requestRetentionPolicy(ScreenshotRetentionPolicy)
        case confirmRetentionPolicy
        case cancelRetentionPolicyReview
        case exportStarted(id: UUID, screenshotID: UUID, destination: ExportDestination)
        case exportFinished(id: UUID, outcome: BackgroundOperation.Outcome)
        case copySucceeded
        case retryError
        case dismissError
        case delegate(Delegate)

        enum Delegate: Equatable {
            case operationStarted(BackgroundOperation)
            case operationPhase(id: UUID, phase: BackgroundOperation.Phase, detail: String?)
            case operationFinished(id: UUID, outcome: BackgroundOperation.Outcome, date: Date)
            case cleanupCompleted(id: UUID, didCleanUp: Bool)
            case showToast(message: String, symbol: String)
        }
    }

    private enum CancelID {
        case capture
        case load
        case persistence
        case clear
    }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.screenshotPersistenceClient) var screenshotPersistenceClient
    @Dependency(\.screenshotRetentionClient) var screenshotRetentionClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setActiveDevice(let identity):
                state.activeDeviceID = identity?.stableID ?? DeviceIdentity.unknownID
                state.activeDeviceName = identity?.displayName
                return .none

            case .onAppear:
                guard !state.didLoadPersistence else { return .none }
                state.retentionPolicy = screenshotRetentionClient.load()
                return .send(.loadPersistence)

            case .loadPersistence:
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing else { return .none }
                state.didLoadPersistence = true
                state.isLoadingPersistence = true
                state.persistenceLoadGeneration += 1
                let generation = state.persistenceLoadGeneration
                state.errorMessage = nil
                state.errorRecovery = nil
                PerformanceSignposts.screenshotPersistence("load-start")
                return .run { send in
                    await send(.persistenceLoaded(generation: generation, try screenshotPersistenceClient.load()))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.persistenceLoadFailed(
                        generation: generation,
                        String(localized: "Could not load saved screenshots: \(error.localizedDescription)")
                    ))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case .persistenceLoaded(let generation, let persisted):
                guard state.isLoadingPersistence,
                      generation == state.persistenceLoadGeneration else { return .none }
                state.isLoadingPersistence = false
                state.errorMessage = nil
                state.errorRecovery = nil
                PerformanceSignposts.screenshotPersistence(
                    "load-success",
                    itemCount: persisted.metadata.count
                )
                var invalidImageCount = 0
                var seenIDs = Set<UUID>()
                let loaded: [ScreenshotEntry] = persisted.metadata.compactMap { entry in
                    guard seenIDs.insert(entry.id).inserted,
                          let data = persisted.files[entry.id],
                          UIImage(data: data) != nil else {
                        invalidImageCount += 1
                        return nil
                    }
                    return ScreenshotEntry(
                        id: entry.id,
                        timestamp: entry.timestamp,
                        data: data,
                        originDeviceID: entry.originDeviceID,
                        originDeviceName: entry.originDeviceName,
                        pixelWidth: entry.pixelWidth,
                        pixelHeight: entry.pixelHeight,
                        byteCount: entry.byteCount,
                        note: entry.note
                    )
                }
                state.screenshots = Self.retainedScreenshots(
                    loaded,
                    countLimit: state.retentionPolicy.countLimit,
                    byteLimit: state.retentionPolicy.byteLimit
                )
                sanitizeGallerySelection(&state)
                let trimmedForBudget = state.screenshots.count < loaded.count
                let foundCorruption = !persisted.warnings.isEmpty || invalidImageCount > 0
                if foundCorruption || trimmedForBudget {
                    state.errorMessage = foundCorruption
                        ? String(localized: "Some saved screenshots were damaged, missing, or exceeded the storage limit and were removed.")
                        : String(localized: "Older screenshots were removed to match the selected retention policy.")
                }
                if trimmedForBudget || foundCorruption || persisted.needsMigration {
                    state.isPersisting = true
                    return persist(state)
                }
                return .none

            case .persistenceLoadFailed(let generation, let message):
                guard state.isLoadingPersistence,
                      generation == state.persistenceLoadGeneration else { return .none }
                state.isLoadingPersistence = false
                state.errorMessage = message
                state.errorRecovery = .load
                PerformanceSignposts.screenshotPersistence("load-failed")
                return .none

            case .takeScreenshot:
                guard !state.isCapturing,
                      !state.isLoadingPersistence,
                      !state.isPersisting,
                      !state.isClearing else { return .none }
                state.isCapturing = true
                state.captureGeneration += 1
                let generation = state.captureGeneration
                state.activeCaptureGeneration = generation
                let operationID = uuid()
                state.activeCaptureOperationID = operationID
                let deviceID = state.activeDeviceID
                state.errorMessage = nil
                state.errorRecovery = nil

                let operation = BackgroundOperation(
                    id: operationID,
                    deviceID: deviceID,
                    deviceName: state.activeDeviceName ?? String(localized: "Unknown device"),
                    workspace: .screens,
                    kind: .capture,
                    objectName: String(localized: "Screenshot"),
                    phase: .running,
                    completedUnits: nil,
                    totalUnits: nil,
                    detail: String(localized: "Capturing from the connected device…"),
                    isCancellable: true,
                    isTransportDependent: true,
                    cleanupState: .notRequired,
                    outcome: nil,
                    retryPayload: .captureScreenshot,
                    startedAt: date.now,
                    finishedAt: nil
                )
                let captureEffect: Effect<Action> = .run { send in
                    let data = try await adbClient.takeScreenshot()
                    await send(.captureResponse(
                        generation: generation,
                        deviceID: deviceID,
                        .success(data)
                    ))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.captureResponse(
                        generation: generation,
                        deviceID: deviceID,
                        .failure(error)
                    ))
                }
                .cancellable(id: CancelID.capture, cancelInFlight: true)
                return .concatenate(
                    .send(.delegate(.operationStarted(operation))),
                    captureEffect
                )

            case .cancelCapture:
                guard state.isCapturing else { return .none }
                let operationID = state.activeCaptureOperationID
                state.isCapturing = false
                state.activeCaptureGeneration = nil
                state.activeCaptureOperationID = nil
                return .merge(
                    .cancel(id: CancelID.capture),
                    operationID.map {
                        .send(.delegate(.cleanupCompleted(id: $0, didCleanUp: false)))
                    } ?? .none
                )

            case .captureResponse(let generation, let deviceID, let result):
                guard state.activeCaptureGeneration == generation,
                      state.activeDeviceID == deviceID else { return .none }
                state.activeCaptureGeneration = nil
                return .send(.screenshotCaptured(result))

            case .cancelAll:
                if let rollback = state.pendingPersistenceRollback {
                    state.screenshots = rollback
                    state.selectedScreenshot = state.pendingSelectedScreenshotRollback
                }
                if let isSelecting = state.pendingIsSelectingRollback {
                    state.isSelecting = isSelecting
                    state.selectedScreenshotIDs = state.pendingSelectedScreenshotIDsRollback ?? []
                    state.viewerScreenshotID = state.pendingViewerScreenshotIDRollback
                    state.comparisonScreenshotIDs = state.pendingComparisonScreenshotIDsRollback ?? []
                }
                state.isCapturing = false
                state.activeCaptureGeneration = nil
                let captureOperationID = state.activeCaptureOperationID
                state.activeCaptureOperationID = nil
                state.isLoadingPersistence = false
                state.persistenceLoadGeneration += 1
                state.isPersisting = false
                state.isClearing = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                state.pendingRetentionPolicyRollback = nil
                state.pendingRetentionPolicySave = nil
                state.pendingBulkDeleteItems.removeAll()
                state.pendingBulkPreflightResults.removeAll()
                clearGallerySelectionRollback(&state)
                return .merge(
                    .cancel(id: CancelID.capture),
                    .cancel(id: CancelID.load),
                    .cancel(id: CancelID.persistence),
                    .cancel(id: CancelID.clear),
                    captureOperationID.map {
                        .send(.delegate(.cleanupCompleted(id: $0, didCleanUp: false)))
                    } ?? .none
                )

            case .screenshotCaptured(.success(let data)):
                state.isCapturing = false
                guard UIImage(data: data) != nil else {
                    state.errorMessage = String(localized: "Failed to decode screenshot image")
                    state.errorRecovery = .capture
                    return finishCaptureFailure(&state, message: state.errorMessage ?? String(localized: "Capture failed"))
                }
                guard data.count <= state.retentionPolicy.byteLimit else {
                    state.errorMessage = String(localized: "The screenshot is larger than the selected retention limit.")
                    state.errorRecovery = nil
                    return finishCaptureFailure(&state, message: state.errorMessage ?? String(localized: "Capture failed"))
                }
                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                captureGallerySelectionRollback(&state)
                let entry = ScreenshotEntry(
                    id: uuid(),
                    timestamp: date.now,
                    data: data,
                    originDeviceID: state.activeDeviceID,
                    originDeviceName: state.activeDeviceName
                )
                state.screenshots.insert(entry, at: 0)
                let candidates = state.screenshots
                state.screenshots = Self.retainedScreenshots(
                    candidates,
                    countLimit: state.retentionPolicy.countLimit,
                    byteLimit: state.retentionPolicy.byteLimit
                )
                sanitizeGallerySelection(&state)
                if state.screenshots.count < candidates.count {
                    state.errorMessage = String(localized: "Older screenshots were removed to match the selected retention policy.")
                }
                state.isPersisting = true
                let phase: Effect<Action> = state.activeCaptureOperationID.map {
                    .send(.delegate(.operationPhase(
                        id: $0,
                        phase: .running,
                        detail: String(localized: "Saving to the local gallery…")
                    )))
                } ?? .none
                return .merge(phase, persist(state))

            case .screenshotCaptured(.failure(let error)):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                state.errorRecovery = .capture
                return finishCaptureFailure(&state, message: error.localizedDescription)

            case .deleteScreenshot(let entry):
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing else { return .none }
                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                state.screenshots.removeAll { $0.id == entry.id }
                state.selectedScreenshotIDs.remove(entry.id)
                state.comparisonScreenshotIDs.removeAll { $0 == entry.id }
                if state.viewerScreenshotID == entry.id { state.viewerScreenshotID = nil }
                if state.selectedScreenshot?.id == entry.id {
                    state.selectedScreenshot = nil
                }
                state.isPersisting = true
                return persist(state)

            case .selectScreenshot(let entry):
                state.selectedScreenshot = entry
                return .none

            case .setSelectionMode(let isSelecting):
                state.isSelecting = isSelecting
                if !isSelecting {
                    state.selectedScreenshotIDs.removeAll()
                    state.comparisonScreenshotIDs.removeAll()
                }
                return .none

            case .toggleSelection(let id):
                guard state.screenshots.contains(where: { $0.id == id }) else { return .none }
                state.isSelecting = true
                if !state.selectedScreenshotIDs.insert(id).inserted {
                    state.selectedScreenshotIDs.remove(id)
                }
                state.comparisonScreenshotIDs.removeAll()
                return .none

            case .selectAll:
                state.isSelecting = true
                state.selectedScreenshotIDs = Set(state.screenshots.map(\.id))
                state.comparisonScreenshotIDs.removeAll()
                return .none

            case .setSortOrder(let order):
                state.sortOrder = order
                return .none

            case .setGrouping(let grouping):
                state.grouping = grouping
                return .none

            case .openViewer(let id):
                guard state.screenshots.contains(where: { $0.id == id }) else { return .none }
                state.viewerScreenshotID = id
                return .none

            case .closeViewer:
                state.viewerScreenshotID = nil
                return .none

            case .openComparison:
                guard state.canCompareSelection else { return .none }
                state.comparisonScreenshotIDs = state.selectedScreenshots.map(\.id)
                return .none

            case .closeComparison:
                state.comparisonScreenshotIDs.removeAll()
                return .none

            case .saveNote(let id, let rawNote):
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing,
                      let index = state.screenshots.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                let note = Self.boundedNote(rawNote)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                state.screenshots[index].note = note.isEmpty ? nil : note
                if state.selectedScreenshot?.id == id {
                    state.selectedScreenshot?.note = note.isEmpty ? nil : note
                }
                state.isPersisting = true
                return persist(state)

            case .bulkDeleteSelected:
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing,
                      !state.selectedScreenshotIDs.isEmpty else { return .none }
                let selectedIDs = state.selectedScreenshotIDs
                let entries = state.screenshots.filter { selectedIDs.contains($0.id) }
                let existingIDs = Set(entries.map(\.id))
                let missingIDs = selectedIDs.subtracting(existingIDs)
                state.pendingBulkDeleteItems = entries.map {
                    ScreenshotBulkResult(id: $0.id, fileName: $0.fileName, outcome: .success)
                }
                state.pendingBulkPreflightResults = missingIDs.map {
                    ScreenshotBulkResult(
                        id: $0,
                        fileName: $0.uuidString + ".png",
                        outcome: .failure(String(localized: "Screenshot is no longer in the gallery."))
                    )
                }
                state.bulkResults.removeAll()

                guard !entries.isEmpty else {
                    state.bulkResults = state.pendingBulkPreflightResults
                    state.pendingBulkPreflightResults.removeAll()
                    state.isSelecting = false
                    state.selectedScreenshotIDs.removeAll()
                    return .none
                }

                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                captureGallerySelectionRollback(&state)
                state.screenshots.removeAll { selectedIDs.contains($0.id) }
                if let selectedID = state.selectedScreenshot?.id, selectedIDs.contains(selectedID) {
                    state.selectedScreenshot = nil
                }
                if let viewerID = state.viewerScreenshotID, selectedIDs.contains(viewerID) {
                    state.viewerScreenshotID = nil
                }
                state.comparisonScreenshotIDs.removeAll()
                state.isPersisting = true
                return persist(state)

            case .requestBulkDelete:
                guard !state.selectedScreenshotIDs.isEmpty,
                      !state.isLoadingPersistence, !state.isPersisting, !state.isClearing else {
                    return .none
                }
                state.isBulkDeleteConfirmationPresented = true
                return .none

            case .confirmBulkDelete:
                guard state.isBulkDeleteConfirmationPresented else { return .none }
                state.isBulkDeleteConfirmationPresented = false
                return .send(.bulkDeleteSelected)

            case .cancelBulkDelete:
                state.isBulkDeleteConfirmationPresented = false
                return .none

            case .dismissBulkResults:
                state.bulkResults.removeAll()
                return .none

            case .clearAll:
                guard !state.isLoadingPersistence, !state.isClearing, !state.isPersisting else { return .none }
                state.isClearing = true
                state.errorMessage = nil
                state.errorRecovery = nil
                return .run { send in
                    try screenshotPersistenceClient.clear()
                    await send(.clearCompleted(.success(())))
                } catch: { error, send in
                    await send(.clearCompleted(.failure(error)))
                }
                .cancellable(id: CancelID.clear, cancelInFlight: true)

            case .clearCompleted(.success):
                state.isClearing = false
                state.screenshots.removeAll()
                state.selectedScreenshot = nil
                state.selectedScreenshotIDs.removeAll()
                state.isSelecting = false
                state.viewerScreenshotID = nil
                state.comparisonScreenshotIDs.removeAll()
                state.bulkResults.removeAll()
                return .none

            case .clearCompleted(.failure(let error)):
                state.isClearing = false
                state.errorMessage = String(localized: "Could not delete saved screenshots: \(error.localizedDescription)")
                state.errorRecovery = .clear
                return .none

            case .requestRetentionPolicy(let policy):
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing,
                      policy != state.retentionPolicy else { return .none }
                let retained = Self.retainedScreenshots(
                    state.screenshots,
                    countLimit: policy.countLimit,
                    byteLimit: policy.byteLimit
                )
                let retainedIDs = Set(retained.map(\.id))
                let evicted = state.screenshots.filter { !retainedIDs.contains($0.id) }
                guard !evicted.isEmpty else { return .send(.setRetentionPolicy(policy)) }
                state.retentionReview = ScreenshotRetentionReview(
                    proposedPolicy: policy,
                    evictedScreenshotIDs: evicted.map(\.id),
                    reclaimedByteCount: evicted.reduce(0) { $0 + $1.byteCount }
                )
                return .none

            case .confirmRetentionPolicy:
                guard let review = state.retentionReview else { return .none }
                state.retentionReview = nil
                return .send(.setRetentionPolicy(review.proposedPolicy))

            case .cancelRetentionPolicyReview:
                state.retentionReview = nil
                return .none

            case .setRetentionPolicy(let policy):
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing,
                      policy != state.retentionPolicy else { return .none }
                state.retentionReview = nil
                let previousPolicy = state.retentionPolicy
                let previousScreenshots = state.screenshots
                state.retentionPolicy = policy
                state.screenshots = Self.retainedScreenshots(
                    state.screenshots,
                    countLimit: policy.countLimit,
                    byteLimit: policy.byteLimit
                )

                guard state.screenshots != previousScreenshots else {
                    return .run { _ in screenshotRetentionClient.save(policy) }
                }
                state.pendingPersistenceRollback = previousScreenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                captureGallerySelectionRollback(&state)
                state.pendingRetentionPolicyRollback = previousPolicy
                state.pendingRetentionPolicySave = policy
                if let selectedID = state.selectedScreenshot?.id,
                   !state.screenshots.contains(where: { $0.id == selectedID }) {
                    state.selectedScreenshot = nil
                }
                sanitizeGallerySelection(&state)
                state.isPersisting = true
                return persist(state)

            case .exportStarted(let id, let screenshotID, let destination):
                guard state.activeExports[id] == nil,
                      let screenshot = state.screenshots.first(where: { $0.id == screenshotID }) else {
                    return .none
                }
                state.activeExports[id] = destination
                let operation = BackgroundOperation(
                    id: id,
                    deviceID: screenshot.originDeviceID,
                    deviceName: screenshot.originDeviceName ?? String(localized: "Unknown device"),
                    workspace: .screens,
                    kind: .export,
                    objectName: screenshot.fileName,
                    phase: .running,
                    completedUnits: nil,
                    totalUnits: Int64(screenshot.byteCount),
                    detail: destination == .photos
                        ? String(localized: "Saving to Photos…")
                        : String(localized: "Waiting for the share sheet…"),
                    isCancellable: false,
                    isTransportDependent: false,
                    cleanupState: .notRequired,
                    outcome: nil,
                    retryPayload: nil,
                    startedAt: date.now,
                    finishedAt: nil
                )
                return .send(.delegate(.operationStarted(operation)))

            case .exportFinished(let id, let outcome):
                guard state.activeExports.removeValue(forKey: id) != nil else { return .none }
                return .send(.delegate(.operationFinished(
                    id: id,
                    outcome: outcome,
                    date: date.now
                )))

            case .copySucceeded:
                return .send(.delegate(.showToast(
                    message: String(localized: "Screenshot copied"),
                    symbol: "doc.on.doc"
                )))

            case .persistenceSucceeded:
                let captureOperationID = state.activeCaptureOperationID
                state.activeCaptureOperationID = nil
                state.isPersisting = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                let retentionPolicyToSave = state.pendingRetentionPolicySave
                state.pendingRetentionPolicyRollback = nil
                state.pendingRetentionPolicySave = nil
                clearGallerySelectionRollback(&state)
                let bulkItems = state.pendingBulkDeleteItems
                let bulkPreflight = state.pendingBulkPreflightResults
                if !bulkItems.isEmpty || !bulkPreflight.isEmpty {
                    state.bulkResults = bulkItems + bulkPreflight
                    state.pendingBulkDeleteItems.removeAll()
                    state.pendingBulkPreflightResults.removeAll()
                    state.selectedScreenshotIDs.removeAll()
                    state.isSelecting = false
                }
                PerformanceSignposts.screenshotPersistence(
                    "save-success",
                    itemCount: state.screenshots.count
                )
                let captureEffect: Effect<Action> = captureOperationID.map {
                    .send(.delegate(.operationFinished(
                        id: $0,
                        outcome: .success(summary: String(localized: "Screenshot saved to the local gallery.")),
                        date: date.now
                    )))
                } ?? .none
                let retentionEffect: Effect<Action> = retentionPolicyToSave.map { policy in
                    .run { _ in screenshotRetentionClient.save(policy) }
                } ?? .none
                let deletionSummary = bulkItems.count == 1
                    ? String(localized: "Deleted 1 screenshot")
                    : String(localized: "Deleted \(bulkItems.count) screenshots")
                let bulkEffect: Effect<Action> = bulkItems.isEmpty ? .none : .send(.delegate(.showToast(
                    message: bulkPreflight.isEmpty
                        ? deletionSummary
                        : String(localized: "Deleted \(bulkItems.count); \(bulkPreflight.count) could not be deleted"),
                    symbol: bulkPreflight.isEmpty ? "trash" : "exclamationmark.triangle"
                )))
                return .merge(captureEffect, retentionEffect, bulkEffect)

            case .persistenceFailed(let message):
                let captureOperationID = state.activeCaptureOperationID
                let bulkItems = state.pendingBulkDeleteItems
                let bulkPreflight = state.pendingBulkPreflightResults
                state.activeCaptureOperationID = nil
                if let rollback = state.pendingPersistenceRollback {
                    state.screenshots = rollback
                    state.selectedScreenshot = state.pendingSelectedScreenshotRollback
                }
                if let policyRollback = state.pendingRetentionPolicyRollback {
                    state.retentionPolicy = policyRollback
                }
                if let isSelecting = state.pendingIsSelectingRollback {
                    state.isSelecting = isSelecting
                    state.selectedScreenshotIDs = state.pendingSelectedScreenshotIDsRollback ?? []
                    state.viewerScreenshotID = state.pendingViewerScreenshotIDRollback
                    state.comparisonScreenshotIDs = state.pendingComparisonScreenshotIDsRollback ?? []
                }
                state.isPersisting = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                state.pendingRetentionPolicyRollback = nil
                state.pendingRetentionPolicySave = nil
                clearGallerySelectionRollback(&state)
                if !bulkItems.isEmpty || !bulkPreflight.isEmpty {
                    state.bulkResults = bulkItems.map {
                        ScreenshotBulkResult(id: $0.id, fileName: $0.fileName, outcome: .failure(message))
                    } + bulkPreflight
                }
                state.pendingBulkDeleteItems.removeAll()
                state.pendingBulkPreflightResults.removeAll()
                state.errorMessage = message
                state.errorRecovery = nil
                PerformanceSignposts.screenshotPersistence("save-failed")
                return captureOperationID.map {
                    .send(.delegate(.operationFinished(
                        id: $0,
                        outcome: .failure(message: message, retryable: true),
                        date: date.now
                    )))
                } ?? .none

            case .retryError:
                switch state.errorRecovery {
                case .capture:
                    return .send(.takeScreenshot)
                case .load:
                    return .send(.loadPersistence)
                case .clear:
                    return .send(.clearAll)
                case nil:
                    return .none
                }

            case .dismissError:
                state.errorMessage = nil
                state.errorRecovery = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private func finishCaptureFailure(_ state: inout State, message: String) -> Effect<Action> {
        guard let operationID = state.activeCaptureOperationID else { return .none }
        state.activeCaptureOperationID = nil
        return .send(.delegate(.operationFinished(
            id: operationID,
            outcome: .failure(message: message, retryable: true),
            date: date.now
        )))
    }

    private func persist(_ state: State) -> Effect<Action> {
        let metadata = state.screenshots.map {
            PersistedScreenshotEntry(
                id: $0.id,
                timestamp: $0.timestamp,
                fileName: $0.fileName,
                originDeviceID: $0.originDeviceID,
                originDeviceName: $0.originDeviceName,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                byteCount: $0.byteCount,
                note: $0.note
            )
        }
        let files = Dictionary(uniqueKeysWithValues: state.screenshots.map { ($0.id, $0.data) })
        return .run { send in
            try screenshotPersistenceClient.save(metadata, files)
            await send(.persistenceSucceeded)
        } catch: { error, send in
            guard !(error is CancellationError) else { return }
            await send(.persistenceFailed(String(localized: "Could not save screenshots: \(error.localizedDescription)")))
        }
        .cancellable(id: CancelID.persistence, cancelInFlight: false)
    }

    private func sanitizeGallerySelection(_ state: inout State) {
        let validIDs = Set(state.screenshots.map(\.id))
        state.selectedScreenshotIDs.formIntersection(validIDs)
        state.comparisonScreenshotIDs.removeAll { !validIDs.contains($0) }
        if let viewerID = state.viewerScreenshotID, !validIDs.contains(viewerID) {
            state.viewerScreenshotID = nil
        }
        if let selectedID = state.selectedScreenshot?.id, !validIDs.contains(selectedID) {
            state.selectedScreenshot = nil
        }
        if state.selectedScreenshotIDs.isEmpty { state.isSelecting = false }
    }

    private func captureGallerySelectionRollback(_ state: inout State) {
        state.pendingSelectedScreenshotIDsRollback = state.selectedScreenshotIDs
        state.pendingIsSelectingRollback = state.isSelecting
        state.pendingViewerScreenshotIDRollback = state.viewerScreenshotID
        state.pendingComparisonScreenshotIDsRollback = state.comparisonScreenshotIDs
    }

    private func clearGallerySelectionRollback(_ state: inout State) {
        state.pendingSelectedScreenshotIDsRollback = nil
        state.pendingIsSelectingRollback = nil
        state.pendingViewerScreenshotIDRollback = nil
        state.pendingComparisonScreenshotIDsRollback = nil
    }

    static func boundedNote(_ note: String, byteLimit: Int = 2_048) -> String {
        guard note.utf8.count > byteLimit else { return note }
        return String(decoding: note.utf8.prefix(byteLimit), as: UTF8.self)
    }

    static func retainedScreenshots(
        _ screenshots: [ScreenshotEntry],
        countLimit: Int = 50,
        byteLimit: Int = screenshotStorageByteLimit
    ) -> [ScreenshotEntry] {
        var retained: [ScreenshotEntry] = []
        var retainedBytes = 0
        for screenshot in screenshots.prefix(max(0, countLimit)) {
            guard screenshot.data.count <= byteLimit - retainedBytes else { break }
            retained.append(screenshot)
            retainedBytes += screenshot.data.count
        }
        return retained
    }
}
