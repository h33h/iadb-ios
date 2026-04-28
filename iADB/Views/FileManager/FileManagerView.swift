import SwiftUI
import UniformTypeIdentifiers
import ComposableArchitecture

struct FileManagerView: View {
    let store: StoreOf<FileManagerFeature>
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var showingPathInput = false
    @State private var pathInput = ""
    @State private var showingImportPicker = false
    @State private var showingDeleteConfirm = false
    @State private var entryToDelete: FileEntry?
    @State private var showingShareSheet = false
    @State private var shareData: Data?
    @State private var shareFileName: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Path bar
                PathBar(
                    path: store.currentPath,
                    canGoBack: store.pathHistory.count > 1,
                    onBack: { store.send(.goBack) },
                    onUp: { store.send(.navigateUp) },
                    onPathTap: {
                        pathInput = store.currentPath
                        showingPathInput = true
                    }
                )

                // File list
                if store.isLoading {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                } else if let error = store.errorMessage {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text("Error")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            store.send(.loadDirectory(path: nil))
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if store.entries.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Empty Directory")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(store.entries) { entry in
                        FileEntryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.send(.navigateTo(entry))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                    showingDeleteConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                if !entry.isDirectory {
                                    Button {
                                        store.send(.pullFile(entry))
                                    } label: {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingNewFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showingImportPicker = true
                        } label: {
                            Label("Upload File", systemImage: "arrow.up.circle")
                        }
                        Button {
                            store.send(.loadDirectory(path: nil))
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            })
            .alert("New Folder", isPresented: $showingNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    store.send(.createDirectory(name: newFolderName))
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Go to Path", isPresented: $showingPathInput) {
                TextField("Path", text: $pathInput)
                Button("Go") {
                    store.send(.navigateToPath(pathInput))
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete?", isPresented: $showingDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let entry = entryToDelete {
                        store.send(.deleteFile(entry))
                    }
                }
            } message: {
                Text("Delete \(entryToDelete?.name ?? "this item")?")
            }
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        store.send(.pushFileData(data: data, fileName: url.lastPathComponent))
                    }
                }
            }
            .onChange(of: store.pulledFileData) { _, newValue in
                if let data = newValue {
                    shareData = data
                    shareFileName = store.selectedFile?.name ?? "file"
                    showingShareSheet = true
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let data = shareData {
                    ShareSheet(data: data, fileName: shareFileName)
                }
            }
        }
    }
}

struct PathBar: View {
    let path: String
    let canGoBack: Bool
    let onBack: () -> Void
    let onUp: () -> Void
    let onPathTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Button(action: onUp) {
                Image(systemName: "arrow.up")
            }

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .onTapGesture(perform: onPathTap)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
}

struct FileEntryRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.iconName)
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.permissions)
                        .font(.system(.caption2, design: .monospaced))
                    if !entry.size.isEmpty {
                        Text(entry.displaySize)
                            .font(.caption2)
                    }
                    Text("\(entry.date) \(entry.time)")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let data: Data
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: tempURL)
        return UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
