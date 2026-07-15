import SwiftUI
import UIKit
import Photos
import ComposableArchitecture

struct ScreenshotView: View {
    enum Layout {
        case compact
        case regular
    }

    let store: StoreOf<ScreenshotFeature>
    let layout: Layout
    @State private var shareImages: [UIImage] = []
    @State private var shareFileNames: [String] = []
    @State private var showingShareSheet = false
    @State private var activeShareOperationIDs: [UUID] = []
    @State private var showingClearConfirmation = false
    @State private var screenshotToDelete: ScreenshotFeature.ScreenshotEntry?
    @State private var photoSaveAlert: PhotoSaveAlert?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    init(store: StoreOf<ScreenshotFeature>, layout: Layout = .compact) {
        self.store = store
        self.layout = layout
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityToolbar
                }

                if store.isCapturing {
                    StatusBannerView(
                        style: .progress,
                        message: String(localized: "Capturing screenshot..."),
                        showsProgress: true,
                        actionTitle: String(localized: "Cancel"),
                        onAction: { store.send(.cancelCapture) }
                    )
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                if store.isLoadingPersistence || store.isPersisting || store.isClearing {
                    StatusBannerView(
                        style: .progress,
                        message: store.isLoadingPersistence
                            ? String(localized: "Loading saved screenshots...")
                            : (store.isClearing
                                ? String(localized: "Deleting screenshots...")
                                : String(localized: "Saving screenshots...")),
                        showsProgress: true
                    )
                    .padding(.horizontal)
                    .padding(.top, store.isCapturing ? 0 : 8)
                }

                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: errorRecoveryTitle,
                        onDismiss: { store.send(.dismissError) },
                        onAction: errorRecoveryTitle == nil ? nil : { store.send(.retryError) }
                    )
                        .padding(.horizontal)
                        .padding(.top, store.isCapturing ? 0 : 8)
                }

                galleryContent
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .accessibilityIdentifier("workspace.screens")
            .navigationTitle("Screens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                store.send(.onAppear)
            }
            .toolbar {
                if !dynamicTypeSize.isAccessibilitySize {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                    captureButton

                    if !store.screenshots.isEmpty {
                        Button(store.isSelecting ? String(localized: "Done") : String(localized: "Select")) {
                            store.send(.setSelectionMode(!store.isSelecting))
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("screens.selection.toggle")

                        galleryMenu
                    }
                }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.isSelecting {
                    screenshotBulkBar
                }
            }
            .fullScreenCover(item: viewerBinding) { screenshot in
                FullScreenScreenshot(entry: screenshot) {
                    store.send(.closeViewer)
                } onShare: {
                    share(screenshot)
                } onSave: {
                    saveToPhotos(screenshot)
                } onCopy: {
                    copy(screenshot)
                } onDelete: {
                    store.send(.deleteScreenshot(screenshot))
                    store.send(.closeViewer)
                }
            }
            .fullScreenCover(isPresented: comparisonBinding) {
                ScreenshotComparisonView(
                    entries: store.comparisonScreenshots,
                    onDismiss: { store.send(.closeComparison) }
                )
            }
            .sheet(isPresented: $showingShareSheet, onDismiss: finishDismissedShareIfNeeded) {
                if !shareImages.isEmpty {
                    ShareImageSheet(images: shareImages, fileNames: shareFileNames) { outcome in
                        let operationIDs = activeShareOperationIDs
                        activeShareOperationIDs.removeAll()
                        for operationID in operationIDs {
                            store.send(.exportFinished(id: operationID, outcome: outcome))
                        }
                        showingShareSheet = false
                    }
                }
            }
            .sheet(isPresented: bulkResultsBinding) {
                ScreenshotBulkResultsView(
                    results: store.bulkResults,
                    onDone: { store.send(.dismissBulkResults) }
                )
                .iadbAdaptiveSheetHeight()
            }
            .alert(
                "Delete Selected Screenshots?",
                isPresented: bulkDeleteConfirmationBinding
            ) {
                Button("Delete \(store.selectedScreenshotIDs.count)", role: .destructive) {
                    store.send(.confirmBulkDelete)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelBulkDelete) }
            } message: {
                Text("Each selected local capture will report its own result. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete All Screenshots?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    store.send(.clearAll)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all saved screenshots from iADB.")
            }
            .confirmationDialog(
                "Delete Screenshot?",
                isPresented: Binding(
                    get: { screenshotToDelete != nil },
                    set: { if !$0 { screenshotToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let screenshotToDelete {
                        store.send(.deleteScreenshot(screenshotToDelete))
                    }
                    screenshotToDelete = nil
                }
                Button("Cancel", role: .cancel) { screenshotToDelete = nil }
            } message: {
                Text("This permanently removes the selected screenshot.")
            }
            .alert(item: $photoSaveAlert) { alert in
                if alert.offersSettings {
                    return Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        primaryButton: .default(Text("Open Settings")) {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        },
                        secondaryButton: .cancel()
                    )
                }
                return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private var captureButton: some View {
        Button("Capture", systemImage: "camera") {
            store.send(.takeScreenshot)
        }
        .labelStyle(.titleAndIcon)
        .disabled(isBusy)
        .accessibilityLabel("Capture screenshot")
        .accessibilityIdentifier("screens.primary.capture")
    }

    private var accessibilityToolbar: some View {
        HStack(spacing: IADBDesign.spacing12) {
            Button("Capture", systemImage: "camera") {
                store.send(.takeScreenshot)
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: IADBDesign.minimumHitTarget)
            .disabled(isBusy)
            .accessibilityLabel("Capture screenshot")
            .accessibilityIdentifier("screens.primary.capture")

            if !store.screenshots.isEmpty {
                accessibilityGalleryMenu
                .buttonStyle(.bordered)
                .frame(minHeight: IADBDesign.minimumHitTarget)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, IADBDesign.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var accessibilityGalleryMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button(
                store.isSelecting ? String(localized: "Done Selecting") : String(localized: "Select Screenshots")
            ) {
                store.send(.setSelectionMode(!store.isSelecting))
            }
            .disabled(isBusy)
            Divider()
            Picker("Sort", selection: sortBinding) {
                ForEach(ScreenshotSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker("Group by", selection: groupingBinding) {
                ForEach(ScreenshotGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            Divider()
            Button("Select All", systemImage: "checkmark.circle") {
                store.send(.selectAll)
            }
            Button("Delete All Screenshots", systemImage: "trash", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(isBusy)
        }
        .accessibilityLabel("Gallery options")
        .accessibilityIdentifier("screens.gallery.options")
    }

    private var galleryMenu: some View {
        Menu("Gallery", systemImage: "line.3.horizontal.decrease.circle") {
            Picker("Sort", selection: sortBinding) {
                ForEach(ScreenshotSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker("Group by", selection: groupingBinding) {
                ForEach(ScreenshotGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            Divider()
            Button("Select All", systemImage: "checkmark.circle") {
                store.send(.selectAll)
            }
            Button("Delete All Screenshots", systemImage: "trash", role: .destructive) {
                showingClearConfirmation = true
            }
            .disabled(isBusy)
        }
        .accessibilityLabel("Gallery options")
    }

    @ViewBuilder
    private var galleryContent: some View {
        if store.screenshots.isEmpty && !store.isCapturing {
            ContentUnavailableView {
                Label("No Screenshots Yet", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Capture the Android screen. Local captures remain available when the device disconnects.")
            } actions: {
                Button("Capture", systemImage: "camera") { store.send(.takeScreenshot) }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(isBusy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: IADBDesign.spacing20) {
                    ForEach(gallerySections) { section in
                        Section {
                            LazyVGrid(columns: screenshotColumns, spacing: IADBDesign.spacing16) {
                                ForEach(section.entries) { screenshot in
                                    ScreenshotThumbnail(
                                        entry: screenshot,
                                        isSelecting: store.isSelecting,
                                        isSelected: store.selectedScreenshotIDs.contains(screenshot.id),
                                        isInspectorSelected: store.selectedScreenshot?.id == screenshot.id,
                                        onTap: { selectOrOpen(screenshot) },
                                        onOpen: {
                                            store.send(.selectScreenshot(screenshot))
                                            store.send(.openViewer(screenshot.id))
                                        },
                                        onToggleSelection: { store.send(.toggleSelection(screenshot.id)) }
                                    )
                                }
                            }
                        } header: {
                            HStack {
                                Text(section.title).font(.headline)
                                Spacer()
                                Text("\(section.entries.count)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    storagePolicyFooter
                }
                .padding(IADBDesign.spacing16)
            }
            .accessibilityIdentifier("screens.grid")
        }
    }

    private var screenshotBulkBar: some View {
        BulkActionBar(
            selectionCount: store.selectedScreenshotIDs.count,
            selectionLabel: store.selectedScreenshotIDs.count == 1
                ? String(localized: "1 screenshot")
                : String(localized: "\(store.selectedScreenshotIDs.count) screenshots"),
            actions: [
                BulkActionItem(
                    id: "share",
                    title: "Share",
                    symbol: "square.and.arrow.up",
                    emphasis: .secondary,
                    isEnabled: !store.selectedScreenshots.isEmpty,
                    action: shareSelected
                ),
                BulkActionItem(
                    id: "save",
                    title: "Save",
                    symbol: "square.and.arrow.down",
                    emphasis: .secondary,
                    isEnabled: !store.selectedScreenshots.isEmpty,
                    action: saveSelectedToPhotos
                ),
                BulkActionItem(
                    id: "compare",
                    title: "Compare",
                    symbol: "rectangle.split.2x1",
                    emphasis: .primary,
                    isEnabled: store.canCompareSelection,
                    action: { store.send(.openComparison) }
                ),
                BulkActionItem(
                    id: "delete",
                    title: "Delete",
                    symbol: "trash",
                    emphasis: .destructive,
                    isEnabled: !store.selectedScreenshotIDs.isEmpty && !isBusy,
                    action: { store.send(.requestBulkDelete) }
                ),
                BulkActionItem(
                    id: "clear",
                    title: "Clear Selection",
                    symbol: nil,
                    emphasis: .secondary,
                    action: { store.send(.setSelectionMode(false)) }
                )
            ]
        )
    }

    private var storagePolicyFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local gallery")
                .font(.subheadline.weight(.semibold))
            Text("\(store.screenshots.count) of \(store.retentionPolicy.countLimit) captures · \(ByteCountFormatter.string(fromByteCount: Int64(store.storageByteCount), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(store.retentionPolicy.byteLimit), countStyle: .file)). Change retention in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var sortBinding: Binding<ScreenshotSortOrder> {
        Binding(get: { store.sortOrder }, set: { store.send(.setSortOrder($0)) })
    }

    private var groupingBinding: Binding<ScreenshotGrouping> {
        Binding(get: { store.grouping }, set: { store.send(.setGrouping($0)) })
    }

    private var viewerBinding: Binding<ScreenshotFeature.ScreenshotEntry?> {
        Binding(
            get: { store.viewerScreenshot },
            set: { if $0 == nil { store.send(.closeViewer) } }
        )
    }

    private var comparisonBinding: Binding<Bool> {
        Binding(
            get: { store.comparisonScreenshots.count == 2 },
            set: { if !$0 { store.send(.closeComparison) } }
        )
    }

    private var bulkResultsBinding: Binding<Bool> {
        Binding(
            get: { !store.bulkResults.isEmpty },
            set: { if !$0 { store.send(.dismissBulkResults) } }
        )
    }

    private var bulkDeleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.isBulkDeleteConfirmationPresented },
            set: { if !$0 { store.send(.cancelBulkDelete) } }
        )
    }

    private func selectOrOpen(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        if store.isSelecting {
            store.send(.toggleSelection(screenshot.id))
        } else if layout == .regular {
            if store.selectedScreenshot?.id == screenshot.id {
                store.send(.selectScreenshot(nil))
            } else {
                store.send(.selectScreenshot(screenshot))
            }
        } else {
            store.send(.selectScreenshot(screenshot))
            store.send(.openViewer(screenshot.id))
        }
    }

    private var gallerySections: [ScreenshotGallerySection] {
        var sectionOrder: [String] = []
        var entriesByKey: [String: [ScreenshotFeature.ScreenshotEntry]] = [:]
        var titlesByKey: [String: String] = [:]
        let calendar = Calendar.current

        for screenshot in store.sortedScreenshots {
            let key: String
            let title: String
            switch store.grouping {
            case .day:
                let day = calendar.startOfDay(for: screenshot.timestamp)
                key = "day:\(day.timeIntervalSince1970)"
                title = day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            case .device:
                key = "device:\(screenshot.originDeviceID)"
                title = screenshot.originDeviceName ?? String(localized: "Unknown Device")
            }
            if entriesByKey[key] == nil { sectionOrder.append(key) }
            entriesByKey[key, default: []].append(screenshot)
            titlesByKey[key] = title
        }

        return sectionOrder.map {
            ScreenshotGallerySection(
                id: $0,
                title: titlesByKey[$0] ?? String(localized: "Screenshots"),
                entries: entriesByKey[$0] ?? []
            )
        }
    }

    private var isBusy: Bool {
        store.isCapturing || store.isLoadingPersistence || store.isPersisting || store.isClearing
    }

    private var screenshotColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        if layout == .regular {
            return Array(
                repeating: GridItem(.flexible(), spacing: IADBDesign.spacing12),
                count: 4
            )
        }
        let minimum: CGFloat = 148
        return [GridItem(.adaptive(minimum: minimum, maximum: 230), spacing: IADBDesign.spacing16)]
    }

    private var errorRecoveryTitle: String? {
        switch store.errorRecovery {
        case .capture: String(localized: "Retry Capture")
        case .load: String(localized: "Retry Load")
        case .clear: String(localized: "Retry Delete")
        case nil: nil
        }
    }

    private func share(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        share([screenshot])
    }

    private func shareSelected() {
        share(store.selectedScreenshots)
    }

    private func share(_ screenshots: [ScreenshotFeature.ScreenshotEntry]) {
        let valid = screenshots.compactMap { screenshot -> (ScreenshotFeature.ScreenshotEntry, UIImage)? in
            UIImage(data: screenshot.data).map { (screenshot, $0) }
        }
        guard !valid.isEmpty else { return }
        activeShareOperationIDs = valid.map { screenshot, _ in
            let operationID = UUID()
            store.send(.exportStarted(
                id: operationID,
                screenshotID: screenshot.id,
                destination: .share
            ))
            return operationID
        }
        shareImages = valid.map(\.1)
        shareFileNames = valid.map { screenshot, _ in
            screenshot.fileName
        }
        showingShareSheet = true
    }

    private func saveSelectedToPhotos() {
        let screenshots = store.selectedScreenshots
        guard !screenshots.isEmpty else { return }
        Task {
            var saved = 0
            var failed = 0
            for screenshot in screenshots {
                guard let image = UIImage(data: screenshot.data) else {
                    failed += 1
                    continue
                }
                let operationID = UUID()
                store.send(.exportStarted(
                    id: operationID,
                    screenshotID: screenshot.id,
                    destination: .photos
                ))
                do {
                    try await PhotoLibrarySaver.save(image)
                    saved += 1
                    store.send(.exportFinished(
                        id: operationID,
                        outcome: .success(summary: String(localized: "Saved to Photos"))
                    ))
                } catch {
                    failed += 1
                    store.send(.exportFinished(
                        id: operationID,
                        outcome: .failure(message: error.localizedDescription, retryable: false)
                    ))
                }
            }
            let savedSummary = saved == 1
                ? String(localized: "Saved 1 screenshot. \(failed) failed.")
                : String(localized: "Saved \(saved) screenshots. \(failed) failed.")
            photoSaveAlert = PhotoSaveAlert(
                title: failed == 0 ? String(localized: "Saved") : String(localized: "Partial Result"),
                message: savedSummary
            )
        }
    }

    private func saveToPhotos(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        guard let image = UIImage(data: screenshot.data) else {
            photoSaveAlert = PhotoSaveAlert(
                title: String(localized: "Could Not Save"),
                message: String(localized: "The screenshot image is invalid.")
            )
            return
        }
        let operationID = UUID()
        store.send(.exportStarted(
            id: operationID,
            screenshotID: screenshot.id,
            destination: .photos
        ))

        Task {
            do {
                try await PhotoLibrarySaver.save(image)
                store.send(.exportFinished(
                    id: operationID,
                    outcome: .success(summary: String(localized: "Saved to Photos"))
                ))
                photoSaveAlert = PhotoSaveAlert(
                    title: String(localized: "Saved"),
                    message: String(localized: "The screenshot was added to Photos.")
                )
            } catch PhotoLibrarySaver.SaveError.accessDenied {
                store.send(.exportFinished(
                    id: operationID,
                    outcome: .failure(message: String(localized: "Photos access was denied."), retryable: false)
                ))
                photoSaveAlert = PhotoSaveAlert(
                    title: String(localized: "Photos Access Required"),
                    message: String(localized: "Allow iADB to add photos in Settings, then try again."),
                    offersSettings: true
                )
            } catch {
                store.send(.exportFinished(
                    id: operationID,
                    outcome: .failure(message: error.localizedDescription, retryable: false)
                ))
                photoSaveAlert = PhotoSaveAlert(title: String(localized: "Could Not Save"), message: error.localizedDescription)
            }
        }
    }

    private func copy(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        guard let image = UIImage(data: screenshot.data) else { return }
        UIPasteboard.general.image = image
        store.send(.copySucceeded)
    }

    private func finishDismissedShareIfNeeded() {
        guard !activeShareOperationIDs.isEmpty else { return }
        let operationIDs = activeShareOperationIDs
        activeShareOperationIDs.removeAll()
        for operationID in operationIDs {
            store.send(.exportFinished(id: operationID, outcome: .cancelled))
        }
    }
}

private struct ScreenshotGallerySection: Identifiable {
    let id: String
    let title: String
    let entries: [ScreenshotFeature.ScreenshotEntry]
}

private struct ScreenshotBulkResultsView: View {
    let results: [ScreenshotBulkResult]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List(results) { result in
                HStack(alignment: .top, spacing: IADBDesign.spacing12) {
                    Image(systemName: resultSymbol(result))
                        .foregroundStyle(resultColor(result))
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.fileName)
                            .font(.subheadline.monospaced())
                            .lineLimit(2)
                        Text(resultMessage(result))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle("Delete Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private func resultSymbol(_ result: ScreenshotBulkResult) -> String {
        if case .success = result.outcome { "checkmark.circle" } else { "exclamationmark.triangle" }
    }

    private func resultColor(_ result: ScreenshotBulkResult) -> Color {
        if case .success = result.outcome { .green } else { .orange }
    }

    private func resultMessage(_ result: ScreenshotBulkResult) -> String {
        switch result.outcome {
        case .success: String(localized: "Deleted")
        case .failure(let message): message
        }
    }
}

private struct PhotoSaveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var offersSettings = false
}

private enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case accessDenied
        case failed

        var errorDescription: String? {
            switch self {
            case .accessDenied: return String(localized: "Photos access was denied.")
            case .failed: return String(localized: "Photos could not save the screenshot.")
            }
        }
    }

    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.accessDenied
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { saved, error in
                if saved {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? SaveError.failed)
                }
            }
        }
    }
}

struct ScreenshotThumbnail: View {
    let entry: ScreenshotFeature.ScreenshotEntry
    let isSelecting: Bool
    let isSelected: Bool
    let isInspectorSelected: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                ZStack(alignment: .topTrailing) {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(isSelected ? Color.white : Color.white, isSelected ? Color.accentColor : Color.black.opacity(0.45))
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
                        .stroke(
                            isSelected || isInspectorSelected ? Color.accentColor : Color(uiColor: .separator),
                            lineWidth: isSelected || isInspectorSelected ? 3 : 0.5
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.timestamp, style: .time)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("\(imageSize) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(entry.originDeviceName ?? String(localized: "Unknown device"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: IADBDesign.selectionAnimationDuration),
            value: isSelected
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: IADBDesign.selectionAnimationDuration),
            value: isInspectorSelected
        )
        .accessibilityLabel(
            String(
                localized: "Screenshot from \(entry.originDeviceName ?? String(localized: "Unknown device")), \(entry.timestamp.formatted(date: .abbreviated, time: .shortened)), \(imageSize), \(isSelected ? String(localized: "selected") : String(localized: "not selected"))"
            )
        )
        .accessibilityHint(
            isSelecting
                ? String(localized: "Toggles selection")
                : isInspectorSelected
                    ? String(localized: "Deselects this screenshot; activate twice to open the viewer")
                    : String(localized: "Opens details; activate twice to open the viewer")
        )
        .accessibilityAction(
            named: isSelected ? String(localized: "Deselect") : String(localized: "Select"),
            onToggleSelection
        )
        .accessibilityAction(named: "Open viewer", onOpen)
        .accessibilityIdentifier("screens.thumbnail.\(entry.id.uuidString)")
    }

    private var image: UIImage {
        ScreenshotImageCache.shared.image(for: entry) ?? UIImage()
    }

    private var imageSize: String {
        guard entry.pixelWidth > 0, entry.pixelHeight > 0 else { return String(localized: "Unknown size") }
        return "\(entry.pixelWidth)×\(entry.pixelHeight)"
    }
}

struct ScreenshotInspectorView: View {
    let store: StoreOf<ScreenshotFeature>
    let entry: ScreenshotFeature.ScreenshotEntry
    @State private var note: String
    @State private var showingDeleteConfirmation = false

    init(store: StoreOf<ScreenshotFeature>, entry: ScreenshotFeature.ScreenshotEntry) {
        self.store = store
        self.entry = entry
        _note = State(initialValue: entry.note ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IADBDesign.spacing16) {
                Image(uiImage: ScreenshotImageCache.shared.image(for: entry) ?? UIImage())
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
                    .accessibilityLabel("Selected Android screenshot")

                HStack(spacing: IADBDesign.spacing8) {
                    Button("Open Viewer", systemImage: "arrow.up.left.and.arrow.down.right") {
                        store.send(.openViewer(entry.id))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.image = UIImage(data: entry.data)
                        store.send(.copySucceeded)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }

                GroupBox {
                    VStack(spacing: 0) {
                        TechnicalRow(
                            label: "Captured",
                            value: entry.timestamp.formatted(date: .abbreviated, time: .standard)
                        )
                        Divider()
                        TechnicalRow(
                            label: "Device",
                            value: entry.originDeviceName ?? String(localized: "Unknown Device")
                        )
                        if entry.originDeviceID == DeviceIdentity.unknownID {
                            Divider()
                            TechnicalRow(label: "Provenance", value: String(localized: "Legacy origin"))
                        }
                        Divider()
                        TechnicalRow(
                            label: "Dimensions",
                            value: "\(entry.pixelWidth) × \(entry.pixelHeight)",
                            monospacedValue: true
                        )
                        Divider()
                        TechnicalRow(
                            label: "Size",
                            value: ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
                        )
                    }
                } label: {
                    Label("Capture Details", systemImage: "info.circle")
                }

                VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                    Text("Note").font(.headline)
                    TextEditor(text: $note)
                        .frame(minHeight: 96)
                        .padding(IADBDesign.spacing8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
                        .accessibilityLabel("Screenshot note")
                    HStack {
                        Text("Stored locally with this capture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Note") { store.send(.saveNote(entry.id, note)) }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .disabled(
                                store.isPersisting ||
                                ScreenshotFeature.boundedNote(note).trimmingCharacters(in: .whitespacesAndNewlines) == (entry.note ?? "")
                            )
                    }
                }

                GroupBox {
                    Button("Delete Screenshot", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .disabled(store.isPersisting || store.isClearing)
                } label: {
                    Label("Danger Zone", systemImage: "exclamationmark.triangle")
                }
            }
            .padding()
        }
        .navigationTitle("Screenshot Details")
        .confirmationDialog(
            "Delete Screenshot?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.send(.deleteScreenshot(entry)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the local screenshot.")
        }
        .onChange(of: entry.note) { _, value in note = value ?? "" }
    }
}

struct FullScreenScreenshot: View {
    let entry: ScreenshotFeature.ScreenshotEntry
    let onDismiss: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showingDeleteConfirmation = false
    @State private var fittedImageScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let minScale: CGFloat = 1.0
    private static let maxScale: CGFloat = 6.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let proposed = lastScale * value
                                scale = min(max(proposed, Self.minScale), Self.maxScale)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale == Self.minScale {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > Self.minScale else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        animateZoom {
                            if scale > Self.minScale {
                                setScale(Self.minScale)
                            } else {
                                setScale(min(actualSizeFactor, 2.5))
                            }
                        }
                    }
                    .accessibilityLabel("Full-screen Android screenshot")
                    .accessibilityHint("Use the visible Fit and 100 percent controls to inspect the image")
                    .accessibilityAction(named: "Zoom in") { zoomIn() }
                    .accessibilityAction(named: "Zoom out") { zoomOut() }
                    .accessibilityAction(named: "Fit image") { resetZoom() }
                    .accessibilityAction(named: "Show at 100 percent") { zoomActualSize() }
                    .onAppear { updateFittedScale(for: geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateFittedScale(for: size) }
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Delete Screenshot", systemImage: "trash", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Screenshot actions")

                    Button("Close", systemImage: "xmark.circle.fill", action: onDismiss)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Close screenshot")
                }
                HStack(spacing: 8) {
                    Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Share screenshot")
                    Button("Save", systemImage: "square.and.arrow.down", action: onSave)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Save screenshot to Photos")
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Copy screenshot")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
            .padding()

            zoomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
        }
        .confirmationDialog(
            "Delete Screenshot?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the local screenshot.")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button("Fit", action: resetZoom)
                .frame(minWidth: 44, minHeight: 44)

            Button("100%", action: zoomActualSize)
                .frame(minWidth: 52, minHeight: 44)

            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(scale <= Self.minScale)
            .accessibilityLabel("Zoom out")

            Text("\(zoomPercentage)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 52)
                .accessibilityHidden(true)

            Button(action: zoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(scale >= Self.maxScale)
            .accessibilityLabel("Zoom in")

            Button(action: resetZoom) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 44, height: 44)
            }
            .disabled(scale <= Self.minScale)
            .accessibilityLabel("Reset zoom")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func zoomIn() {
        animateZoom { setScale(min(scale + 0.75, Self.maxScale)) }
    }

    private func zoomOut() {
        animateZoom { setScale(max(scale - 0.75, Self.minScale)) }
    }

    private func resetZoom() {
        animateZoom { setScale(Self.minScale) }
    }

    private func zoomActualSize() {
        animateZoom { setScale(actualSizeFactor) }
    }

    private func animateZoom(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.2), updates)
        }
    }

    private func setScale(_ newScale: CGFloat) {
        let bounded = min(max(newScale, Self.minScale), Self.maxScale)
        scale = bounded
        lastScale = bounded
        if bounded == Self.minScale {
            offset = .zero
            lastOffset = .zero
        }
    }

    private var image: UIImage { ScreenshotImageCache.shared.image(for: entry) ?? UIImage() }

    private var actualSizeFactor: CGFloat {
        min(Self.maxScale, max(Self.minScale, 1 / max(fittedImageScale, 0.001)))
    }

    private var zoomPercentage: Int {
        max(1, Int((fittedImageScale * scale * 100).rounded()))
    }

    private func updateFittedScale(for availableSize: CGSize) {
        guard image.size.width > 0, image.size.height > 0 else {
            fittedImageScale = 1
            return
        }
        fittedImageScale = min(
            availableSize.width / image.size.width,
            availableSize.height / image.size.height
        )
    }
}

private struct ScreenshotComparisonView: View {
    let entries: [ScreenshotFeature.ScreenshotEntry]
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(entries) { entry in
                        VStack(spacing: IADBDesign.spacing8) {
                            Image(uiImage: ScreenshotImageCache.shared.image(for: entry) ?? UIImage())
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .clipped()
                                .accessibilityLabel(
                                    "Compared screenshot from \(entry.originDeviceName ?? String(localized: "Unknown device"))"
                                )
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: geometry.size.width / CGFloat(max(entries.count, 1)))
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Compare Screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Fit") { setScale(1) }
                        .frame(minHeight: 44)
                    Button("100%") { setScale(2) }
                        .frame(minHeight: 44)
                    Spacer()
                    Text("\(Int(scale * 100))%")
                        .font(.caption.monospacedDigit())
                        .accessibilityLabel("Zoom \(Int(scale * 100)) percent")
                }
            }
        }
    }

    private func setScale(_ newValue: CGFloat) {
        if reduceMotion {
            scale = newValue
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { scale = newValue }
        }
    }
}

struct ShareImageSheet: UIViewControllerRepresentable {
    let images: [UIImage]
    let fileNames: [String]
    let onCompletion: (BackgroundOperation.Outcome) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var urls: [URL] = []
        do {
            for (index, image) in images.enumerated() {
                guard let data = image.pngData() else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                let fileName = fileNames.indices.contains(index)
                    ? fileNames[index]
                    : "screenshot-\(index + 1).png"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
        } catch {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            Task { @MainActor in
                onCompletion(.failure(message: error.localizedDescription, retryable: false))
            }
            return UIActivityViewController(activityItems: [], applicationActivities: nil)
        }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            let outcome: BackgroundOperation.Outcome
            if let error {
                outcome = .failure(message: error.localizedDescription, retryable: false)
            } else if completed {
                outcome = .success(summary: String(localized: "Share completed"))
            } else {
                outcome = .cancelled
            }
            Task { @MainActor in onCompletion(outcome) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
