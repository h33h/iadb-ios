import ComposableArchitecture
import Foundation
import UIKit
import Testing
@testable import iADB

@MainActor
struct ScreenshotFeatureTests {
    @Test
    func captureCanBeCancelled() async {
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = {
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }
        await store.send(.cancelCapture) {
            $0.isCapturing = false
        }
    }

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
        let testDate = Date(timeIntervalSince1970: 1000)

        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { imageData }
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.uuid = .constant(testUUID)
            $0.date = .constant(testDate)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }

        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            $0.pendingPersistenceRollback = []
            $0.screenshots = [
                ScreenshotFeature.ScreenshotEntry(id: testUUID, timestamp: testDate, data: imageData)
            ]
            $0.isPersisting = true
        }
        await store.receive(\.persistenceSucceeded) {
            $0.isPersisting = false
            $0.pendingPersistenceRollback = nil
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
            $0.errorRecovery = .capture
        }
    }

    @Test
    func takeScreenshotInvalidData() async {
        let testUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { Data([0x00, 0x01]) } // not valid image
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.uuid = .constant(testUUID)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.errorMessage = nil
        }

        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            $0.errorMessage = "Failed to decode screenshot image"
            $0.errorRecovery = .capture
        }
    }

    @Test
    func retentionIsBoundedToFiftyScreenshots() async {
        let existing = (0..<50).map { index in
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                data: Self.testImageData
            )
        }
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: existing, isCapturing: true)
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.uuid = .constant(newID)
            $0.date = .constant(Date(timeIntervalSince1970: 100))
        }

        store.exhaustivity = .off
        await store.send(.screenshotCaptured(.success(Self.testImageData)))
        await store.receive(\.persistenceSucceeded)
        store.exhaustivity = .on

        #expect(store.state.screenshots.count == 50)
        #expect(store.state.screenshots.first?.id == newID)
        #expect(!store.state.screenshots.contains { $0.id == existing[49].id })
    }

    @Test
    func retentionAlsoHonorsCumulativeByteBudget() {
        let entries = (0..<3).map { index in
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                data: Data(repeating: UInt8(index), count: 6)
            )
        }

        let retained = ScreenshotFeature.retainedScreenshots(entries, countLimit: 50, byteLimit: 10)
        #expect(retained.count == 1)
        #expect(retained.first?.id == entries.first?.id)
    }

    @Test
    func persistenceFailureIsShown() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let store = TestStore(
            initialState: ScreenshotFeature.State(isCapturing: true)
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in
                throw ADBError.commandFailed("disk full")
            }
            $0.uuid = .constant(id)
            $0.date = .constant(Date(timeIntervalSince1970: 1))
        }

        await store.send(.screenshotCaptured(.success(Self.testImageData))) {
            $0.isCapturing = false
            $0.pendingPersistenceRollback = []
            $0.screenshots = [ScreenshotFeature.ScreenshotEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: 1),
                data: Self.testImageData
            )]
            $0.isPersisting = true
        }
        await store.receive(\.persistenceFailed) {
            $0.screenshots = []
            $0.isPersisting = false
            $0.pendingPersistenceRollback = nil
            $0.errorMessage = "Could not save screenshots: Command failed: disk full"
        }

        #expect(store.state.errorMessage?.contains("disk full") == true)
    }

    @Test
    func deleteScreenshot() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: [entry])
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
        }

        await store.send(.deleteScreenshot(entry)) {
            $0.pendingPersistenceRollback = [entry]
            $0.screenshots = []
            $0.isPersisting = true
        }
        await store.receive(\.persistenceSucceeded) {
            $0.isPersisting = false
            $0.pendingPersistenceRollback = nil
        }
    }

    @Test
    func clearAll() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            timestamp: Date(),
            data: Data()
        )

        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: [entry])
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.clear = {}
        }

        await store.send(.clearAll) {
            $0.isClearing = true
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.clearCompleted) {
            $0.isClearing = false
            $0.screenshots = []
        }
    }

    @Test
    func selectScreenshot() async {
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
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

    @Test
    func onAppearLoadsPersistence() async {
        let testUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let testDate = Date(timeIntervalSince1970: 1000)
        let imageData = Self.testImageData
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.load = {
                ScreenshotPersistenceBundle(
                    metadata: [PersistedScreenshotEntry(id: testUUID, timestamp: testDate, fileName: "\(testUUID.uuidString).png")],
                    files: [testUUID: imageData]
                )
            }
        }

        await store.send(.onAppear)
        await store.receive(\.loadPersistence) {
            $0.didLoadPersistence = true
            $0.isLoadingPersistence = true
            $0.persistenceLoadGeneration = 1
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.persistenceLoaded) {
            $0.isLoadingPersistence = false
            $0.screenshots = [ScreenshotFeature.ScreenshotEntry(id: testUUID, timestamp: testDate, data: imageData)]
        }
    }

    @Test
    func corruptPersistedFileDoesNotHideValidScreenshots() async {
        let validID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let corruptID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let validDate = Date(timeIntervalSince1970: 31)
        let bundle = ScreenshotPersistenceBundle(
            metadata: [
                PersistedScreenshotEntry(id: validID, timestamp: validDate, fileName: "valid.png"),
                PersistedScreenshotEntry(id: corruptID, timestamp: validDate, fileName: "corrupt.png")
            ],
            files: [validID: Self.testImageData, corruptID: Data("not-a-png".utf8)]
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            isLoadingPersistence: true,
            persistenceLoadGeneration: 1
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
        }

        await store.send(.persistenceLoaded(generation: 1, bundle)) {
            $0.isLoadingPersistence = false
            $0.screenshots = [ScreenshotFeature.ScreenshotEntry(
                id: validID,
                timestamp: validDate,
                data: Self.testImageData
            )]
            $0.errorMessage = "Some saved screenshots were damaged, missing, or exceeded the storage limit and were removed."
            $0.isPersisting = true
        }
        await store.receive(\.persistenceSucceeded) {
            $0.isPersisting = false
        }
    }

    @Test
    func captureIsIgnoredUntilPersistenceCompletes() async {
        let store = TestStore(
            initialState: ScreenshotFeature.State(isPersisting: true)
        ) {
            ScreenshotFeature()
        }

        await store.send(.takeScreenshot)
    }

    @Test
    func clearFailureKeepsScreenshotsAndRetriesClear() async {
        struct DiskError: LocalizedError {
            var errorDescription: String? { "disk is read-only" }
        }
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            timestamp: Date(),
            data: Self.testImageData
        )
        let store = TestStore(
            initialState: ScreenshotFeature.State(screenshots: [entry])
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.clear = { throw DiskError() }
        }

        await store.send(.clearAll) {
            $0.isClearing = true
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.clearCompleted) {
            $0.isClearing = false
            $0.errorMessage = "Could not delete saved screenshots: disk is read-only"
            $0.errorRecovery = .clear
        }
        #expect(store.state.screenshots == [entry])

        await store.send(.retryError)
        await store.receive(\.clearAll) {
            $0.isClearing = true
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.clearCompleted) {
            $0.isClearing = false
            $0.errorMessage = "Could not delete saved screenshots: disk is read-only"
            $0.errorRecovery = .clear
        }
    }

    @Test
    func loadFailureRetriesLoadInsteadOfCapturing() async {
        struct LoadError: LocalizedError {
            var errorDescription: String? { "metadata unavailable" }
        }
        let attempts = LockIsolated(0)
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.load = {
                let attempt = attempts.withValue {
                    $0 += 1
                    return $0
                }
                if attempt == 1 { throw LoadError() }
                return ScreenshotPersistenceBundle(metadata: [], files: [:])
            }
        }

        await store.send(.loadPersistence) {
            $0.didLoadPersistence = true
            $0.isLoadingPersistence = true
            $0.persistenceLoadGeneration = 1
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.persistenceLoadFailed) {
            $0.isLoadingPersistence = false
            $0.errorMessage = "Could not load saved screenshots: metadata unavailable"
            $0.errorRecovery = .load
        }
        await store.send(.retryError)
        await store.receive(\.loadPersistence) {
            $0.isLoadingPersistence = true
            $0.persistenceLoadGeneration = 2
            $0.errorMessage = nil
            $0.errorRecovery = nil
        }
        await store.receive(\.persistenceLoaded) {
            $0.isLoadingPersistence = false
        }
        #expect(store.state.isCapturing == false)
        #expect(store.state.errorMessage == nil)
        #expect(store.state.errorRecovery == nil)
        #expect(attempts.value == 2)
    }

    @Test
    func stalePersistenceLoadCannotOverwriteNewerState() async {
        let current = ScreenshotFeature.ScreenshotEntry(
            id: UUID(),
            timestamp: Date(),
            data: Self.testImageData
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            screenshots: [current],
            isLoadingPersistence: true,
            persistenceLoadGeneration: 2
        )) {
            ScreenshotFeature()
        }

        await store.send(.persistenceLoaded(
            generation: 1,
            ScreenshotPersistenceBundle(metadata: [], files: [:])
        ))
        #expect(store.state.screenshots == [current])
        #expect(store.state.isLoadingPersistence)
    }

    @Test
    func duplicatePersistedIDsAreDeduplicatedWithoutDictionaryTrap() async {
        let id = UUID()
        let date = Date()
        let metadata = PersistedScreenshotEntry(id: id, timestamp: date, fileName: "one.png")
        let bundle = ScreenshotPersistenceBundle(
            metadata: [metadata, metadata],
            files: [id: Self.testImageData]
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            isLoadingPersistence: true,
            persistenceLoadGeneration: 1
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
        }

        store.exhaustivity = .off
        await store.send(.persistenceLoaded(generation: 1, bundle))
        await store.receive(\.persistenceSucceeded)
        store.exhaustivity = .on

        #expect(store.state.screenshots.count == 1)
        #expect(store.state.screenshots.first?.id == id)
    }
}
