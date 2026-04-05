import Foundation
import UIKit
import ComposableArchitecture

@Reducer
struct ScreenshotFeature {
    struct ScreenshotEntry: Equatable, Identifiable {
        let id: UUID
        let timestamp: Date
        let data: Data
    }

    @ObservableState
    struct State: Equatable {
        var screenshots: [ScreenshotEntry] = []
        var isCapturing = false
        var errorMessage: String?
        var selectedScreenshot: ScreenshotEntry?
    }

    enum Action {
        case takeScreenshot
        case screenshotCaptured(Result<Data, Error>)
        case deleteScreenshot(ScreenshotEntry)
        case selectScreenshot(ScreenshotEntry?)
        case clearAll
    }

    private enum CancelID { case capture }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
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
                return .none

            case .screenshotCaptured(.failure(let error)):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .deleteScreenshot(let entry):
                state.screenshots.removeAll { $0.id == entry.id }
                return .none

            case .selectScreenshot(let entry):
                state.selectedScreenshot = entry
                return .none

            case .clearAll:
                state.screenshots.removeAll()
                return .none
            }
        }
    }
}
