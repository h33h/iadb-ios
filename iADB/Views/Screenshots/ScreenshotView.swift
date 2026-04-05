import SwiftUI
import ComposableArchitecture

struct ScreenshotView: View {
    let store: StoreOf<ScreenshotFeature>
    @State private var showingFullScreen = false

    var body: some View {
        NavigationStack {
            VStack {
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
                                        UIImageWriteToSavedPhotosAlbum(screenshot.image, nil, nil, nil)
                                    } label: {
                                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                                    }
                                    Button {
                                        UIPasteboard.general.image = screenshot.image
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

                if let error = store.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Screenshots")
            .navigationBarTitleDisplayMode(.inline)
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
            .fullScreenCover(isPresented: $showingFullScreen) {
                if let screenshot = store.selectedScreenshot {
                    FullScreenScreenshot(entry: screenshot) {
                        showingFullScreen = false
                    }
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
                Image(uiImage: entry.image)
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
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: entry.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = value
                        }
                        .onEnded { _ in
                            withAnimation { scale = 1.0 }
                        }
                )

            HStack(spacing: 16) {
                Button {
                    UIImageWriteToSavedPhotosAlbum(entry.image, nil, nil, nil)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundColor(.white)
                }

                Button {
                    UIPasteboard.general.image = entry.image
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
