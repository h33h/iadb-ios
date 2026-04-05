import ComposableArchitecture
import UIKit
import Testing
@testable import iADB

@MainActor
struct ScreenshotFeatureTests {
    // Create a minimal valid 1x1 PNG for testing
    private static var testImageData: Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @Test
    func takeScreenshotSuccess() async {
        let imageData = Self.testImageData
        let testUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { imageData }
            $0.uuid = .constant(testUUID)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }

        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            #expect($0.screenshots.count == 1)
            #expect($0.screenshots[0].id == testUUID)
            #expect($0.screenshots[0].data == imageData)
        }
    }

    @Test
    func takeScreenshotError() async {
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { throw ADBError.notConnected }
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }

        await store.receive(\.screenshotCaptured.failure) {
            $0.isCapturing = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
        }
    }

    @Test
    func takeScreenshotInvalidData() async {
        let testUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { Data([0x00, 0x01]) } // not valid image
            $0.uuid = .constant(testUUID)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }

        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            $0.errorMessage = "Failed to decode screenshot image"
        }
    }

    @Test
    func deleteScreenshot() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            image: UIImage(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: [entry])
        ) {
            ScreenshotFeature()
        }

        await store.send(.deleteScreenshot(entry)) {
            $0.screenshots = []
        }
    }

    @Test
    func clearAll() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            image: UIImage(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: [entry])
        ) {
            ScreenshotFeature()
        }

        await store.send(.clearAll) {
            $0.screenshots = []
        }
    }

    @Test
    func selectScreenshot() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            image: UIImage(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        }

        await store.send(.selectScreenshot(entry)) {
            $0.selectedScreenshot = entry
        }
    }

    @Test
    func selectScreenshotNil() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            image: UIImage(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(
            initialState: ScreenshotFeature.State(selectedScreenshot: entry)
        ) {
            ScreenshotFeature()
        }

        await store.send(.selectScreenshot(nil)) {
            $0.selectedScreenshot = nil
        }
    }
}
