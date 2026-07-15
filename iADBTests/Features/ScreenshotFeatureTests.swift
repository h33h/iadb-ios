import ComposableArchitecture
import Foundation
import UIKit
import Testing
@testable import iADB

@MainActor
struct ScreenshotFeatureTests {
    @Test
    func exportAndCopyPublishOperationAndFeedbackDelegates() async {
        let screenshotID = UUID(1)
        let exportID = UUID(2)
        let timestamp = Date(timeIntervalSince1970: 100)
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: screenshotID,
            timestamp: timestamp,
            data: Self.testImageData,
            originDeviceID: "serial:test",
            originDeviceName: "Pixel Test"
        )
        let store = TestStore(initialState: ScreenshotFeature.State(screenshots: [entry])) {
            ScreenshotFeature()
        } withDependencies: {
            $0.date = .constant(timestamp)
        }

        await store.send(.exportStarted(
            id: exportID,
            screenshotID: screenshotID,
            destination: .share
        )) {
            $0.activeExports[exportID] = .share
        }
        await store.receive(\.delegate)
        await store.send(.exportFinished(
            id: exportID,
            outcome: .success(summary: "Share completed")
        )) {
            $0.activeExports.removeValue(forKey: exportID)
        }
        await store.receive(\.delegate)
        await store.send(.copySucceeded)
        await store.receive(\.delegate)
    }

    @Test
    func captureCanBeCancelled() async {
        let operationID = UUID(0)
        let startedAt = Date(timeIntervalSince1970: 1)
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = {
                try await Task.sleep(for: .seconds(60))
                return Data()
            }
            $0.uuid = .constant(operationID)
            $0.date = .constant(startedAt)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.captureGeneration = 1
            $0.activeCaptureGeneration = 1
            $0.activeCaptureOperationID = operationID
            $0.errorMessage = nil
        }
        await store.receive(\.delegate)
        await store.send(.cancelCapture) {
            $0.isCapturing = false
            $0.activeCaptureGeneration = nil
            $0.activeCaptureOperationID = nil
        }
        await store.receive(\.delegate)
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
        let identity = DeviceIdentity(
            stableID: "serial:test-device",
            displayName: "Pixel Test",
            adbFingerprint: "test-device"
        )

        let store = TestStore(initialState: ScreenshotFeature.State(
            activeDeviceID: identity.stableID,
            activeDeviceName: identity.displayName
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { imageData }
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.uuid = .constant(testUUID)
            $0.date = .constant(testDate)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.captureGeneration = 1
            $0.activeCaptureGeneration = 1
            $0.activeCaptureOperationID = testUUID
            $0.errorMessage = nil
        }

        await store.receive(\.delegate)
        await store.receive(\.captureResponse) {
            $0.activeCaptureGeneration = nil
        }
        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            $0.pendingPersistenceRollback = []
            $0.pendingSelectedScreenshotIDsRollback = []
            $0.pendingIsSelectingRollback = false
            $0.pendingComparisonScreenshotIDsRollback = []
            $0.screenshots = [
                ScreenshotFeature.ScreenshotEntry(
                    id: testUUID,
                    timestamp: testDate,
                    data: imageData,
                    originDeviceID: identity.stableID,
                    originDeviceName: identity.displayName
                )
            ]
            $0.isPersisting = true
        }
        await store.receive(\.delegate)
        await store.receive(\.persistenceSucceeded) {
            $0.isPersisting = false
            $0.activeCaptureOperationID = nil
            $0.pendingPersistenceRollback = nil
            $0.pendingSelectedScreenshotIDsRollback = nil
            $0.pendingIsSelectingRollback = nil
            $0.pendingComparisonScreenshotIDsRollback = nil
        }
        await store.receive(\.delegate)
    }

    @Test
    func takeScreenshotError() async {
        let operationID = UUID(0)
        let startedAt = Date(timeIntervalSince1970: 1)
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { throw ADBError.notConnected }
            $0.uuid = .constant(operationID)
            $0.date = .constant(startedAt)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.captureGeneration = 1
            $0.activeCaptureGeneration = 1
            $0.activeCaptureOperationID = operationID
            $0.errorMessage = nil
        }

        await store.receive(\.delegate)
        await store.receive(\.captureResponse) {
            $0.activeCaptureGeneration = nil
        }
        await store.receive(\.screenshotCaptured.failure) {
            $0.isCapturing = false
            $0.errorMessage = ADBError.notConnected.localizedDescription
            $0.errorRecovery = .capture
            $0.activeCaptureOperationID = nil
        }
        await store.receive(\.delegate)
    }

    @Test
    func takeScreenshotInvalidData() async {
        let testUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let startedAt = Date(timeIntervalSince1970: 1)
        let store = TestStore(initialState: ScreenshotFeature.State()) {
            ScreenshotFeature()
        } withDependencies: {
            $0.adbClient.takeScreenshot = { Data([0x00, 0x01]) } // not valid image
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.uuid = .constant(testUUID)
            $0.date = .constant(startedAt)
        }

        await store.send(.takeScreenshot) {
            $0.isCapturing = true
            $0.captureGeneration = 1
            $0.activeCaptureGeneration = 1
            $0.activeCaptureOperationID = testUUID
            $0.errorMessage = nil
        }

        await store.receive(\.delegate)
        await store.receive(\.captureResponse) {
            $0.activeCaptureGeneration = nil
        }
        await store.receive(\.screenshotCaptured.success) {
            $0.isCapturing = false
            $0.errorMessage = "Failed to decode screenshot image"
            $0.errorRecovery = .capture
            $0.activeCaptureOperationID = nil
        }
        await store.receive(\.delegate)
    }

    @Test
    func capturesAreNotAutomaticallyRemovedAtTheLegacyCountBoundary() async {
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

        #expect(store.state.screenshots.count == 51)
        #expect(store.state.screenshots.first?.id == newID)
        #expect(store.state.screenshots.contains { $0.id == existing[49].id })
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
    func changingRetentionPolicyTrimsPersistsAndKeepsTheNewestCaptures() async {
        let entries = (0..<30).map { index in
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                data: Self.testImageData
            )
        }
        let savedCount = LockIsolated(0)
        let savedPolicy = LockIsolated<ScreenshotRetentionPolicy?>(nil)
        let store = TestStore(
            initialState: ScreenshotFeature.State(
                screenshots: entries,
                selectedScreenshot: entries.last
            )
        ) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { metadata, _ in
                savedCount.setValue(metadata.count)
            }
            $0.screenshotRetentionClient.save = { savedPolicy.setValue($0) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.setRetentionPolicy(.compact))
        #expect(store.state.retentionPolicy == .compact)
        #expect(store.state.screenshots.count == 25)
        #expect(store.state.screenshots.first?.id == entries.first?.id)
        #expect(store.state.selectedScreenshot == nil)

        await store.receive(\.persistenceSucceeded)
        #expect(savedCount.value == 25)
        #expect(savedPolicy.value == .compact)
    }

    @Test
    func retentionRequestWarnsBeforeEvictionAndRequiresConfirmation() async throws {
        let entries = (0..<30).map { index in
            ScreenshotFeature.ScreenshotEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                data: Self.testImageData
            )
        }
        let store = TestStore(initialState: ScreenshotFeature.State(screenshots: entries)) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
            $0.screenshotRetentionClient.save = { _ in }
        }
        store.exhaustivity = .off

        await store.send(.requestRetentionPolicy(.compact))
        let review = try #require(store.state.retentionReview)
        #expect(review.proposedPolicy == .compact)
        #expect(review.evictedScreenshotIDs.count == 5)
        #expect(review.reclaimedByteCount > 0)
        #expect(store.state.screenshots == entries)
        #expect(store.state.retentionPolicy == .unlimited)

        await store.send(.confirmRetentionPolicy)
        await store.receive(\.setRetentionPolicy)
        #expect(store.state.screenshots.count == 25)
        #expect(store.state.retentionPolicy == .compact)
        await store.receive(\.persistenceSucceeded)
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
            $0.pendingSelectedScreenshotIDsRollback = []
            $0.pendingIsSelectingRollback = false
            $0.pendingComparisonScreenshotIDsRollback = []
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
            $0.pendingSelectedScreenshotIDsRollback = nil
            $0.pendingIsSelectingRollback = nil
            $0.pendingComparisonScreenshotIDsRollback = nil
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
    func captureFromPreviousDeviceCannotEnterLocalGallery() async {
        let store = TestStore(initialState: ScreenshotFeature.State(
            activeDeviceID: "serial:new-device",
            isCapturing: true,
            captureGeneration: 2,
            activeCaptureGeneration: 2
        )) {
            ScreenshotFeature()
        }

        await store.send(.captureResponse(
            generation: 1,
            deviceID: "serial:old-device",
            .success(Self.testImageData)
        ))
        #expect(store.state.screenshots.isEmpty)
        #expect(store.state.activeCaptureGeneration == 2)
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

    @Test
    func selectionCompareAndSortAreReducerOwned() async {
        let first = ScreenshotFeature.ScreenshotEntry(
            id: UUID(1),
            timestamp: Date(timeIntervalSince1970: 10),
            data: Self.testImageData,
            pixelWidth: 100,
            pixelHeight: 200
        )
        let second = ScreenshotFeature.ScreenshotEntry(
            id: UUID(2),
            timestamp: Date(timeIntervalSince1970: 20),
            data: Self.testImageData,
            pixelWidth: 100,
            pixelHeight: 200
        )
        let incompatible = ScreenshotFeature.ScreenshotEntry(
            id: UUID(3),
            timestamp: Date(timeIntervalSince1970: 30),
            data: Self.testImageData,
            pixelWidth: 200,
            pixelHeight: 200
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            screenshots: [first, second, incompatible]
        )) {
            ScreenshotFeature()
        }

        #expect(store.state.sortedScreenshots.map(\.id) == [incompatible.id, second.id, first.id])
        await store.send(.setSortOrder(.oldestFirst)) { $0.sortOrder = .oldestFirst }
        #expect(store.state.sortedScreenshots.map(\.id) == [first.id, second.id, incompatible.id])

        await store.send(.toggleSelection(first.id)) {
            $0.isSelecting = true
            $0.selectedScreenshotIDs = [first.id]
        }
        await store.send(.toggleSelection(second.id)) {
            $0.selectedScreenshotIDs = [first.id, second.id]
        }
        #expect(store.state.canCompareSelection)
        await store.send(.openComparison) {
            $0.comparisonScreenshotIDs = [first.id, second.id]
        }

        await store.send(.toggleSelection(second.id)) {
            $0.selectedScreenshotIDs = [first.id]
            $0.comparisonScreenshotIDs = []
        }
        await store.send(.toggleSelection(incompatible.id)) {
            $0.selectedScreenshotIDs = [first.id, incompatible.id]
        }
        #expect(!store.state.canCompareSelection)
        await store.send(.openComparison)
    }

    @Test
    func bulkDeleteReportsPerItemPartialResult() async throws {
        let existing = ScreenshotFeature.ScreenshotEntry(
            id: UUID(1),
            timestamp: Date(),
            data: Self.testImageData
        )
        let missingID = UUID(2)
        let store = TestStore(initialState: ScreenshotFeature.State(
            screenshots: [existing],
            isSelecting: true,
            selectedScreenshotIDs: [existing.id, missingID]
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in }
        }
        store.exhaustivity = .off

        await store.send(.bulkDeleteSelected)
        #expect(store.state.screenshots.isEmpty)
        #expect(store.state.isPersisting)
        await store.receive(\.persistenceSucceeded)
        await store.receive(\.delegate)

        #expect(!store.state.isSelecting)
        #expect(store.state.selectedScreenshotIDs.isEmpty)
        #expect(store.state.bulkResults.count == 2)
        #expect(store.state.bulkResults.contains {
            $0.id == existing.id && $0.outcome == .success
        })
        let missing = try #require(store.state.bulkResults.first { $0.id == missingID })
        guard case .failure(let message) = missing.outcome else {
            Issue.record("Missing screenshot should have a per-item failure")
            return
        }
        #expect(message.contains("no longer"))
    }

    @Test
    func deleteShortcutOnlyStagesConfirmationForExplicitSelection() async {
        let selectedID = UUID(9)
        let store = TestStore(initialState: ScreenshotFeature.State(
            isSelecting: true,
            selectedScreenshotIDs: [selectedID]
        )) {
            ScreenshotFeature()
        }

        await store.send(.requestBulkDelete) {
            $0.isBulkDeleteConfirmationPresented = true
        }
        await store.send(.confirmBulkDelete) {
            $0.isBulkDeleteConfirmationPresented = false
        }
        await store.receive(\.bulkDeleteSelected) {
            $0.pendingBulkPreflightResults = []
            $0.bulkResults = [ScreenshotBulkResult(
                id: selectedID,
                fileName: selectedID.uuidString + ".png",
                outcome: .failure("Screenshot is no longer in the gallery.")
            )]
            $0.isSelecting = false
            $0.selectedScreenshotIDs = []
        }

        await store.send(.requestBulkDelete)
    }

    @Test
    func bulkDeletePersistenceFailureRollsBackGalleryAndSelection() async throws {
        struct DiskError: LocalizedError {
            var errorDescription: String? { "read-only gallery" }
        }
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(1),
            timestamp: Date(),
            data: Self.testImageData
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            screenshots: [entry],
            isSelecting: true,
            selectedScreenshotIDs: [entry.id],
            viewerScreenshotID: entry.id,
            comparisonScreenshotIDs: [entry.id]
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in throw DiskError() }
        }
        store.exhaustivity = .off

        await store.send(.bulkDeleteSelected)
        await store.receive(\.persistenceFailed)

        #expect(store.state.screenshots == [entry])
        #expect(store.state.selectedScreenshotIDs == [entry.id])
        #expect(store.state.viewerScreenshotID == entry.id)
        #expect(store.state.comparisonScreenshotIDs == [entry.id])
        let result = try #require(store.state.bulkResults.first)
        guard case .failure(let message) = result.outcome else {
            Issue.record("Failed persistence should fail the selected item")
            return
        }
        #expect(message.contains("read-only gallery"))
    }

    @Test
    func noteSaveIsBoundedAndRollsBackOnPersistenceFailure() async throws {
        struct DiskError: LocalizedError {
            var errorDescription: String? { "note write failed" }
        }
        let entry = ScreenshotFeature.ScreenshotEntry(
            id: UUID(1),
            timestamp: Date(),
            data: Self.testImageData,
            note: "Original"
        )
        let store = TestStore(initialState: ScreenshotFeature.State(
            screenshots: [entry],
            selectedScreenshot: entry
        )) {
            ScreenshotFeature()
        } withDependencies: {
            $0.screenshotPersistenceClient.save = { _, _ in throw DiskError() }
        }
        store.exhaustivity = .off
        let oversized = String(repeating: "🙂", count: 2_000)

        await store.send(.saveNote(entry.id, oversized))
        #expect(store.state.screenshots.first?.note?.utf8.count ?? .max <= 2_048)
        await store.receive(\.persistenceFailed)

        #expect(store.state.screenshots == [entry])
        #expect(store.state.selectedScreenshot == entry)
        #expect(store.state.errorMessage?.contains("note write failed") == true)
    }
}
