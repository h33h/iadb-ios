import Foundation
import UIKit
import ComposableArchitecture

@Reducer
struct ScreenshotFeature {
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
    }

    enum Action {
        case onAppear
        case takeScreenshot
        case screenshotCaptured(Result<Data, Error>)
        case deleteScreenshot(ScreenshotEntry)
        case selectScreenshot(ScreenshotEntry?)
        case clearAll
        case loadPersistence
        case persistenceLoaded(ScreenshotPersistenceBundle)
    }

    private enum CancelID { case capture }

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
                state.didLoadPersistence = true
                return .run { send in
                    await send(.persistenceLoaded(screenshotPersistenceClient.load()))
                }

            case .persistenceLoaded(let persisted):
                state.screenshots = persisted.metadata.compactMap { entry in
                    guard let data = persisted.files[entry.id] else { return nil }
                    return ScreenshotEntry(id: entry.id, timestamp: entry.timestamp, data: data)
                }
                return .none

            case .takeScreenshot:
                state.isCapturing = true
                state.errorMessage = nil

                return .run { send in
                    let data = try await adbClient.takeScreenshot()
                    await send(.screenshotCaptured(.success(data)))
                } catch: { error, send in
                    await send(.screenshotCaptured(.failure(error)))
                }
                .cancellable(id: CancelID.capture)

            case .screenshotCaptured(.success(let data)):
                state.isCapturing = false
                guard UIImage(data: data) != nil else {
                    state.errorMessage = "Failed to decode screenshot image"
                    return .none
                }
                let entry = ScreenshotEntry(id: uuid(), timestamp: date.now, data: data)
                state.screenshots.insert(entry, at: 0)
                persist(state)
                return .none

            case .screenshotCaptured(.failure(let error)):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .deleteScreenshot(let entry):
                state.screenshots.removeAll { $0.id == entry.id }
                if state.selectedScreenshot?.id == entry.id {
                    state.selectedScreenshot = nil
                }
                persist(state)
                return .none

            case .selectScreenshot(let entry):
                state.selectedScreenshot = entry
                return .none

            case .clearAll:
                state.screenshots.removeAll()
                state.selectedScreenshot = nil
                screenshotPersistenceClient.clear()
                return .none
            }
        }
    }

    private func persist(_ state: State) {
        let metadata = state.screenshots.map { PersistedScreenshotEntry(id: $0.id, timestamp: $0.timestamp, fileName: $0.fileName) }
        let files = Dictionary(uniqueKeysWithValues: state.screenshots.map { ($0.id, $0.data) })
        screenshotPersistenceClient.save(metadata, files)
    }
}
