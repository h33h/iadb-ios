import Foundation
import UIKit
import ComposableArchitecture

@Reducer
struct ScreenshotFeature {
    enum ErrorRecovery: Equatable {
        case capture
        case load
        case clear
    }

    struct ScreenshotEntry: Equatable, Identifiable {
        let id: UUID
        let timestamp: Date
        let data: Data

        var fileName: String { "\(id.uuidString).png" }
    }

    @ObservableState
    struct State: Equatable {
        var screenshots: [ScreenshotEntry] = []
        var isCapturing = false
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
    }

    enum Action {
        case onAppear
        case takeScreenshot
        case cancelCapture
        case cancelAll
        case screenshotCaptured(Result<Data, Error>)
        case deleteScreenshot(ScreenshotEntry)
        case selectScreenshot(ScreenshotEntry?)
        case clearAll
        case loadPersistence
        case persistenceLoaded(generation: Int, ScreenshotPersistenceBundle)
        case persistenceLoadFailed(generation: Int, String)
        case persistenceSucceeded
        case persistenceFailed(String)
        case clearCompleted(Result<Void, Error>)
        case retryError
        case dismissError
    }

    private enum CancelID {
        case capture
        case load
        case persistence
        case clear
    }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.screenshotPersistenceClient) var screenshotPersistenceClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.didLoadPersistence else { return .none }
                return .send(.loadPersistence)

            case .loadPersistence:
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing else { return .none }
                state.didLoadPersistence = true
                state.isLoadingPersistence = true
                state.persistenceLoadGeneration += 1
                let generation = state.persistenceLoadGeneration
                state.errorMessage = nil
                state.errorRecovery = nil
                return .run { send in
                    await send(.persistenceLoaded(generation: generation, try screenshotPersistenceClient.load()))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.persistenceLoadFailed(
                        generation: generation,
                        "Could not load saved screenshots: \(error.localizedDescription)"
                    ))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)

            case .persistenceLoaded(let generation, let persisted):
                guard state.isLoadingPersistence,
                      generation == state.persistenceLoadGeneration else { return .none }
                state.isLoadingPersistence = false
                state.errorMessage = nil
                state.errorRecovery = nil
                var invalidImageCount = 0
                var seenIDs = Set<UUID>()
                let loaded: [ScreenshotEntry] = persisted.metadata.compactMap { entry in
                    guard seenIDs.insert(entry.id).inserted,
                          let data = persisted.files[entry.id],
                          UIImage(data: data) != nil else {
                        invalidImageCount += 1
                        return nil
                    }
                    return ScreenshotEntry(id: entry.id, timestamp: entry.timestamp, data: data)
                }
                state.screenshots = Self.retainedScreenshots(loaded)
                let trimmedForBudget = state.screenshots.count < loaded.count
                let foundCorruption = !persisted.warnings.isEmpty || invalidImageCount > 0
                if foundCorruption || trimmedForBudget {
                    state.errorMessage = foundCorruption
                        ? "Some saved screenshots were damaged, missing, or exceeded the storage limit and were removed."
                        : "Older screenshots were removed to keep iADB storage under 100 MB."
                }
                if trimmedForBudget || foundCorruption {
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
                return .none

            case .takeScreenshot:
                guard !state.isCapturing,
                      !state.isLoadingPersistence,
                      !state.isPersisting,
                      !state.isClearing else { return .none }
                state.isCapturing = true
                state.errorMessage = nil
                state.errorRecovery = nil

                return .run { send in
                    let data = try await adbClient.takeScreenshot()
                    await send(.screenshotCaptured(.success(data)))
                } catch: { error, send in
                    guard !(error is CancellationError) else { return }
                    await send(.screenshotCaptured(.failure(error)))
                }
                .cancellable(id: CancelID.capture, cancelInFlight: true)

            case .cancelCapture:
                guard state.isCapturing else { return .none }
                state.isCapturing = false
                return .cancel(id: CancelID.capture)

            case .cancelAll:
                state.isCapturing = false
                state.isLoadingPersistence = false
                state.persistenceLoadGeneration += 1
                state.isPersisting = false
                state.isClearing = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                return .merge(
                    .cancel(id: CancelID.capture),
                    .cancel(id: CancelID.load),
                    .cancel(id: CancelID.persistence),
                    .cancel(id: CancelID.clear)
                )

            case .screenshotCaptured(.success(let data)):
                state.isCapturing = false
                guard UIImage(data: data) != nil else {
                    state.errorMessage = "Failed to decode screenshot image"
                    state.errorRecovery = .capture
                    return .none
                }
                guard data.count <= screenshotStorageByteLimit else {
                    state.errorMessage = "The screenshot is larger than iADB's 100 MB storage limit."
                    state.errorRecovery = nil
                    return .none
                }
                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                let entry = ScreenshotEntry(id: uuid(), timestamp: date.now, data: data)
                state.screenshots.insert(entry, at: 0)
                let candidates = state.screenshots
                state.screenshots = Self.retainedScreenshots(candidates)
                if state.screenshots.count < candidates.count {
                    state.errorMessage = "Older screenshots were removed to keep iADB storage under 100 MB."
                }
                state.isPersisting = true
                return persist(state)

            case .screenshotCaptured(.failure(let error)):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                state.errorRecovery = .capture
                return .none

            case .deleteScreenshot(let entry):
                guard !state.isLoadingPersistence, !state.isPersisting, !state.isClearing else { return .none }
                state.pendingPersistenceRollback = state.screenshots
                state.pendingSelectedScreenshotRollback = state.selectedScreenshot
                state.screenshots.removeAll { $0.id == entry.id }
                if state.selectedScreenshot?.id == entry.id {
                    state.selectedScreenshot = nil
                }
                state.isPersisting = true
                return persist(state)

            case .selectScreenshot(let entry):
                state.selectedScreenshot = entry
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
                return .none

            case .clearCompleted(.failure(let error)):
                state.isClearing = false
                state.errorMessage = "Could not delete saved screenshots: \(error.localizedDescription)"
                state.errorRecovery = .clear
                return .none

            case .persistenceSucceeded:
                state.isPersisting = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                return .none

            case .persistenceFailed(let message):
                if let rollback = state.pendingPersistenceRollback {
                    state.screenshots = rollback
                    state.selectedScreenshot = state.pendingSelectedScreenshotRollback
                }
                state.isPersisting = false
                state.pendingPersistenceRollback = nil
                state.pendingSelectedScreenshotRollback = nil
                state.errorMessage = message
                state.errorRecovery = nil
                return .none

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
            }
        }
    }

    private func persist(_ state: State) -> Effect<Action> {
        let metadata = state.screenshots.map { PersistedScreenshotEntry(id: $0.id, timestamp: $0.timestamp, fileName: $0.fileName) }
        let files = Dictionary(uniqueKeysWithValues: state.screenshots.map { ($0.id, $0.data) })
        return .run { send in
            try screenshotPersistenceClient.save(metadata, files)
            await send(.persistenceSucceeded)
        } catch: { error, send in
            guard !(error is CancellationError) else { return }
            await send(.persistenceFailed("Could not save screenshots: \(error.localizedDescription)"))
        }
        .cancellable(id: CancelID.persistence, cancelInFlight: false)
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
