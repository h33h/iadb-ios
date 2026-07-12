import SwiftUI
import UIKit
import Photos
import ComposableArchitecture

struct ScreenshotView: View {
    let store: StoreOf<ScreenshotFeature>
    @State private var shareImage: UIImage?
    @State private var shareFileName = "screenshot.png"
    @State private var showingShareSheet = false
    @State private var showingClearConfirmation = false
    @State private var screenshotToDelete: ScreenshotFeature.ScreenshotEntry?
    @State private var photoSaveAlert: PhotoSaveAlert?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.isCapturing {
                    StatusBannerView(
                        style: .progress,
                        message: "Capturing screenshot...",
                        showsProgress: true,
                        actionTitle: "Cancel",
                        onAction: { store.send(.cancelCapture) }
                    )
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                if store.isLoadingPersistence || store.isPersisting || store.isClearing {
                    StatusBannerView(
                        style: .progress,
                        message: store.isLoadingPersistence
                            ? "Loading saved screenshots..."
                            : (store.isClearing ? "Deleting screenshots..." : "Saving screenshots..."),
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

                ScrollView {
                    VStack(spacing: 18) {
                        captureCard

                        if store.screenshots.isEmpty && !store.isCapturing {
                            ContentUnavailableView {
                                Label("No Screenshots Yet", systemImage: "rectangle.stack.badge.plus")
                            } description: {
                                Text("Capture the Android screen to inspect, compare, share, or save it to Photos.")
                            }
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity)
                        } else if !store.screenshots.isEmpty {
                            HStack {
                                Text("Recent captures")
                                    .font(.headline)
                                Spacer()
                                Text("\(store.screenshots.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }

                        LazyVGrid(columns: screenshotColumns, spacing: 12) {
                            ForEach(store.screenshots) { screenshot in
                                ScreenshotThumbnail(entry: screenshot) {
                                    store.send(.selectScreenshot(screenshot))
                                } onShare: {
                                    share(screenshot)
                                } onSave: {
                                    saveToPhotos(screenshot)
                                } onCopy: {
                                    UIPasteboard.general.image = UIImage(data: screenshot.data) ?? UIImage()
                                } onDelete: {
                                    if !isBusy { screenshotToDelete = screenshot }
                                } isDeleteDisabled: {
                                    isBusy
                                }
                                .contextMenu {
                                    Button {
                                        share(screenshot)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        saveToPhotos(screenshot)
                                    } label: {
                                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                                    }
                                    Button {
                                        UIPasteboard.general.image = UIImage(data: screenshot.data) ?? UIImage()
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    Button(role: .destructive) {
                                        screenshotToDelete = screenshot
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .disabled(isBusy)
                                }
                            }
                        }
                        }
                    }
                    .frame(maxWidth: 980)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Screens")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.send(.onAppear)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.screenshots.isEmpty {
                        Menu {
                            Button("Delete All Screenshots", systemImage: "trash", role: .destructive) {
                                showingClearConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Screenshot actions")
                        .disabled(isBusy)
                    }
                }
            }
            .fullScreenCover(
                item: Binding(
                    get: { store.selectedScreenshot },
                    set: { if $0 == nil { store.send(.selectScreenshot(nil)) } }
                )
            ) { screenshot in
                FullScreenScreenshot(entry: screenshot) {
                    store.send(.selectScreenshot(nil))
                } onShare: {
                    share(screenshot)
                } onSave: {
                    saveToPhotos(screenshot)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let shareImage {
                    ShareImageSheet(image: shareImage, fileName: shareFileName)
                }
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

    private var isBusy: Bool {
        store.isCapturing || store.isLoadingPersistence || store.isPersisting || store.isClearing
    }

    private var screenshotColumns: [GridItem] {
        let count: Int
        if dynamicTypeSize.isAccessibilitySize {
            count = 1
        } else if horizontalSizeClass == .regular {
            count = 3
        } else {
            count = 2
        }

        return Array(
            repeating: GridItem(.flexible(), spacing: IADBDesign.spacing),
            count: count
        )
    }

    private var captureCard: some View {
        IADBCard {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    captureCardVerticalLayout
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            captureIcon
                            captureSummary
                            Spacer(minLength: 8)
                            captureAction
                        }

                        captureCardVerticalLayout
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureCardVerticalLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                captureIcon
                captureSummary
            }
            captureAction
        }
    }

    private var captureIcon: some View {
        Image(systemName: "camera.viewfinder")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 52, height: 52)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Android screen")
                .font(.headline)
            Text(store.screenshots.isEmpty
                 ? "Create your first capture"
                 : "Last captured \(store.screenshots.first?.timestamp.formatted(date: .omitted, time: .shortened) ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var captureAction: some View {
        if store.isCapturing {
            ProgressView()
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Capturing screenshot")
        } else {
            Button {
                store.send(.takeScreenshot)
            } label: {
                Label("Capture", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isBusy)
            .accessibilityLabel("Capture screenshot")
        }
    }

    private var errorRecoveryTitle: String? {
        switch store.errorRecovery {
        case .capture: "Retry Capture"
        case .load: "Retry Load"
        case .clear: "Retry Delete"
        case nil: nil
        }
    }

    private func share(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        guard let image = UIImage(data: screenshot.data) else { return }
        shareImage = image
        shareFileName = "screenshot-\(Int(screenshot.timestamp.timeIntervalSince1970)).png"
        showingShareSheet = true
    }

    private func saveToPhotos(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        guard let image = UIImage(data: screenshot.data) else {
            photoSaveAlert = PhotoSaveAlert(title: "Could Not Save", message: "The screenshot image is invalid.")
            return
        }

        Task {
            do {
                try await PhotoLibrarySaver.save(image)
                photoSaveAlert = PhotoSaveAlert(title: "Saved", message: "The screenshot was added to Photos.")
            } catch PhotoLibrarySaver.SaveError.accessDenied {
                photoSaveAlert = PhotoSaveAlert(
                    title: "Photos Access Required",
                    message: "Allow iADB to add photos in Settings, then try again.",
                    offersSettings: true
                )
            } catch {
                photoSaveAlert = PhotoSaveAlert(title: "Could Not Save", message: error.localizedDescription)
            }
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
            case .accessDenied: return "Photos access was denied."
            case .failed: return "Photos could not save the screenshot."
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
    let onTap: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let isDeleteDisabled: () -> Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color.black
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.timestamp, format: .dateTime.month(.abbreviated).day())
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(entry.timestamp, style: .time)
                            Text("·")
                            Text(imageSize)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Screenshot from \(entry.timestamp.formatted(date: .abbreviated, time: .shortened)), \(imageSize)")
            .accessibilityHint("Opens the screenshot viewer")
            .accessibilityAction(named: "Share", onShare)
            .accessibilityAction(named: "Save to Photos", onSave)
            .accessibilityAction(named: "Copy", onCopy)
            .accessibilityAction(named: "Delete", onDelete)

            Menu {
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button(action: onSave) {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isDeleteDisabled())
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .frame(minWidth: 44, minHeight: 44)
            .padding(4)
            .accessibilityLabel("Actions for screenshot")
        }
    }

    private var image: UIImage {
        UIImage(data: entry.data) ?? UIImage()
    }

    private var imageSize: String {
        guard image.size.width > 0, image.size.height > 0 else { return "Unknown size" }
        return "\(Int(image.size.width))×\(Int(image.size.height))"
    }
}

struct FullScreenScreenshot: View {
    let entry: ScreenshotFeature.ScreenshotEntry
    let onDismiss: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let minScale: CGFloat = 1.0
    private static let maxScale: CGFloat = 6.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: UIImage(data: entry.data) ?? UIImage())
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
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    animateZoom {
                        if scale > Self.minScale {
                            scale = Self.minScale
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                        }
                        lastScale = scale
                    }
                }
                .accessibilityLabel("Full-screen Android screenshot")
                .accessibilityHint("Use the visible zoom controls to inspect the image")
                .accessibilityAction(named: "Zoom in") { zoomIn() }
                .accessibilityAction(named: "Zoom out") { zoomOut() }
                .accessibilityAction(named: "Reset zoom") { resetZoom() }

            HStack(spacing: 8) {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Share screenshot")

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Save screenshot to Photos")

                Button {
                    UIPasteboard.general.image = UIImage(data: entry.data) ?? UIImage()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Copy screenshot")

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Close screenshot")
            }
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()

            zoomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(scale <= Self.minScale)
            .accessibilityLabel("Zoom out")

            Text("\(Int((scale * 100).rounded()))%")
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

    private func animateZoom(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.2), updates)
        }
    }

    private func setScale(_ newScale: CGFloat) {
        scale = newScale
        lastScale = newScale
        if newScale == Self.minScale {
            offset = .zero
            lastOffset = .zero
        }
    }
}

struct ShareImageSheet: UIViewControllerRepresentable {
    let image: UIImage
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
