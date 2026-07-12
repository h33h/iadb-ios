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

                if store.screenshots.isEmpty && !store.isCapturing {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "camera")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Screenshots")
                            .font(.headline)
                        Text("Tap the capture button to take a screenshot of the device screen")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            store.send(.takeScreenshot)
                        } label: {
                            Label("Capture", systemImage: "camera.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                        Spacer()
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(store.screenshots) { screenshot in
                                ScreenshotThumbnail(entry: screenshot) {
                                    store.send(.selectScreenshot(screenshot))
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
                        .padding()
                    }
                }
            }
            .navigationTitle("Screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.send(.onAppear)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isCapturing {
                        Button {
                            store.send(.cancelCapture)
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Cancel screenshot capture")
                    } else {
                        Button {
                            store.send(.takeScreenshot)
                        } label: {
                            Image(systemName: "camera.fill")
                        }
                        .accessibilityLabel("Capture screenshot")
                        .disabled(isBusy)
                    }

                    if !store.screenshots.isEmpty {
                        Button {
                            showingClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete all screenshots")
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

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(uiImage: UIImage(data: entry.data) ?? UIImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(8)
                    .shadow(radius: 2)

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screenshot from \(entry.timestamp.formatted(date: .omitted, time: .shortened))")
        .accessibilityHint("Opens the screenshot viewer")
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
                    withAnimation {
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

            HStack(spacing: 16) {
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
            .padding()
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
