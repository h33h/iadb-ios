import SwiftUI
import UIKit
import ComposableArchitecture

struct ScreenshotView: View {
    let store: StoreOf<ScreenshotFeature>
    @State private var showingFullScreen = false
    @State private var shareImage: UIImage?
    @State private var shareFileName = "screenshot.png"
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.isCapturing {
                    StatusBannerView(style: .progress, message: "Capturing screenshot...", showsProgress: true)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                if let error = store.errorMessage {
                    StatusBannerView(style: .error, message: error)
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
                        Spacer()
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(store.screenshots) { screenshot in
                                ScreenshotThumbnail(entry: screenshot) {
                                    store.send(.selectScreenshot(screenshot))
                                    showingFullScreen = true
                                }
                                .contextMenu {
                                    Button {
                                        share(screenshot)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        UIImageWriteToSavedPhotosAlbum(UIImage(data: screenshot.data) ?? UIImage(), nil, nil, nil)
                                    } label: {
                                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                                    }
                                    Button {
                                        UIPasteboard.general.image = UIImage(data: screenshot.data) ?? UIImage()
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    Button(role: .destructive) {
                                        store.send(.deleteScreenshot(screenshot))
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
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
                        ProgressView()
                    } else {
                        Button {
                            store.send(.takeScreenshot)
                        } label: {
                            Image(systemName: "camera.fill")
                        }
                    }

                    if !store.screenshots.isEmpty {
                        Button {
                            store.send(.clearAll)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingFullScreen, onDismiss: {
                store.send(.selectScreenshot(nil))
            }) {
                if let screenshot = store.selectedScreenshot {
                    FullScreenScreenshot(entry: screenshot) {
                        showingFullScreen = false
                    } onShare: {
                        share(screenshot)
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let shareImage {
                    ShareImageSheet(image: shareImage, fileName: shareFileName)
                }
            }
        }
    }

    private func share(_ screenshot: ScreenshotFeature.ScreenshotEntry) {
        guard let image = UIImage(data: screenshot.data) else { return }
        shareImage = image
        shareFileName = "screenshot-\(Int(screenshot.timestamp.timeIntervalSince1970)).png"
        showingShareSheet = true
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
    }
}

struct FullScreenScreenshot: View {
    let entry: ScreenshotFeature.ScreenshotEntry
    let onDismiss: () -> Void
    let onShare: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    private static let minScale: CGFloat = 1.0
    private static let maxScale: CGFloat = 6.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: UIImage(data: entry.data) ?? UIImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let proposed = lastScale * value
                            scale = min(max(proposed, Self.minScale), Self.maxScale)
                        }
                        .onEnded { _ in
                            lastScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > Self.minScale {
                            scale = Self.minScale
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

                Button {
                    UIImageWriteToSavedPhotosAlbum(UIImage(data: entry.data) ?? UIImage(), nil, nil, nil)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundColor(.white)
                }

                Button {
                    UIPasteboard.general.image = UIImage(data: entry.data) ?? UIImage()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                        .foregroundColor(.white)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
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
