import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ComposableArchitecture

struct FileManagerView: View {
    let store: StoreOf<FileManagerFeature>
    @State private var showingNewFolder = false
    @State private var showingNewFile = false
    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var showingPathInput = false
    @State private var pathInput = ""
    @State private var showingImportPicker = false
    @State private var showingDeleteConfirm = false
    @State private var entryToDelete: FileEntry?
    @State private var showingBatchDeleteConfirm = false
    @State private var entryToRename: FileEntry?
    @State private var entryToMove: FileEntry?
    @State private var renameInput = ""
    @State private var moveInput = ""
    @State private var showingRenameAlert = false
    @State private var showingMoveAlert = false
    @State private var showingShareSheet = false
    @State private var shareData: Data?
    @State private var shareFileName: String = ""

    var body: some View {
        NavigationStack {
            AnyView(navigationContent)
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        store.send(.toggleSelectionMode)
                    } label: {
                        Label(store.isSelectionMode ? "Done Selecting" : "Select Multiple", systemImage: store.isSelectionMode ? "checkmark.circle" : "checklist")
                    }
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showingNewFile = true
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
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
        .alert("New File", isPresented: $showingNewFile) {
            TextField("File name", text: $newFileName)
            Button("Create") {
                store.send(.createFile(name: newFileName))
                newFileName = ""
            }
            Button("Cancel", role: .cancel) { newFileName = "" }
        }
        .alert("Go to Path", isPresented: $showingPathInput) {
            TextField("Path", text: $pathInput)
            Button("Go") {
                store.send(.navigateToPath(pathInput))
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: $showingRenameAlert) {
            TextField("New name", text: $renameInput)
            Button("Save") {
                if let entry = entryToRename {
                    store.send(.renameFile(entry, newName: renameInput))
                }
                entryToRename = nil
                renameInput = ""
            }
            Button("Cancel", role: .cancel) {
                entryToRename = nil
                renameInput = ""
            }
        } message: {
            if let entry = entryToRename {
                Text(entry.fullPath)
            }
        }
        .alert("Move", isPresented: $showingMoveAlert) {
            TextField("Destination path", text: $moveInput)
            Button("Move") {
                if let entry = entryToMove {
                    store.send(.moveFile(entry, destinationPath: moveInput))
                }
                entryToMove = nil
                moveInput = ""
            }
            Button("Cancel", role: .cancel) {
                entryToMove = nil
                moveInput = ""
            }
        } message: {
            if let entry = entryToMove {
                Text("Move \(entry.name) to a new absolute path")
            }
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
        .confirmationDialog("Delete Selected?", isPresented: $showingBatchDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.send(.deleteSelectedFiles)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(store.selectedEntryPaths.count) selected items?")
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
        .onChange(of: store.downloadedFileData, shareDownloadedFileIfNeeded)
        .sheet(isPresented: $showingShareSheet) {
            if let data = shareData {
                ShareSheet(data: data, fileName: shareFileName)
            }
        }
        .onChange(of: showingShareSheet) { _, isPresented in
            if !isPresented {
                shareData = nil
                store.send(.clearDownloadedFile)
            }
        }
        .confirmationDialog(
            store.selectedFile?.name ?? "File Actions",
            isPresented: fileActionsBinding,
            titleVisibility: .visible
        ) {
            if let file = store.selectedFile {
                Button("Preview") {
                    store.send(.previewSelectedFile)
                }
                .disabled(!file.isPreviewable)

                Button("Download") {
                    store.send(.downloadSelectedFile)
                }

                Button("Rename") {
                    entryToRename = file
                    renameInput = file.name
                    showingRenameAlert = true
                    closeFileActions()
                }

                Button("Move") {
                    entryToMove = file
                    moveInput = file.fullPath
                    showingMoveAlert = true
                    closeFileActions()
                }

                Button("Duplicate") {
                    store.send(.duplicateFile(file))
                }

                Button("Copy Path") {
                    UIPasteboard.general.string = file.fullPath
                    closeFileActions()
                }

                Button("Delete", role: .destructive) {
                    entryToDelete = file
                    showingDeleteConfirm = true
                    closeFileActions()
                }
            }
        } message: {
            if let file = store.selectedFile {
                Text(file.fullPath)
            }
        }
        .sheet(
            isPresented: filePreviewBinding
        ) {
            if let file = store.selectedFile, let data = store.previewFileData {
                FilePreviewSheet(entry: file, data: data)
            }
        }
    }

    private var navigationContent: some View {
            VStack(spacing: 0) {
                if store.isLoading, store.fileLoadPurpose != nil {
                    fileLoadingBanner
                }

                if let error = store.errorMessage {
                    StatusBannerView(style: .error, message: error)
                        .padding(.horizontal)
                        .padding(.top, store.isLoading ? 0 : 8)
                        .padding(.bottom, 8)
                }

                // Path bar
                PathBar(
                    path: store.currentPath,
                    canGoBack: store.pathHistory.count > 1,
                    onBack: { store.send(.goBack) },
                    onUp: { store.send(.navigateUp) },
                    onPathTap: showCurrentPathEditor
                )

                if store.isSelectionMode {
                    selectionBanner
                }

                mainContent
            }
    }

    private func showCurrentPathEditor() {
        pathInput = store.currentPath
        showingPathInput = true
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.isLoading {
            loadingContent
        } else if store.errorMessage != nil {
            errorContent
        } else if store.entries.isEmpty {
            emptyContent
        } else {
            entriesList
        }
    }

    private var loadingContent: some View {
        VStack {
            Spacer()
            ProgressView("Loading...")
            Spacer()
        }
    }

    private var errorContent: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text("Error")
                .font(.headline)
            Button("Retry") {
                store.send(.loadDirectory(path: nil))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyContent: some View {
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
    }

    private var entriesList: some View {
        List(store.entries) { entry in
            FileListEntryView(
                entry: entry,
                isSelectionMode: store.isSelectionMode,
                isSelected: store.selectedEntryPaths.contains(entry.fullPath),
                onOpen: openEntry,
                onDownload: downloadEntry,
                onDelete: confirmDelete
            )
        }
        .listStyle(.plain)
    }

    private func openEntry(_ entry: FileEntry) {
        if entry.isDirectory {
            store.send(.navigateTo(entry))
        } else {
            store.send(.selectFile(entry))
        }
    }

    private func downloadEntry(_ entry: FileEntry) {
        store.send(.selectFile(entry))
        store.send(.downloadSelectedFile)
    }

    private func confirmDelete(_ entry: FileEntry) {
        entryToDelete = entry
        showingDeleteConfirm = true
    }

    private func shareDownloadedFileIfNeeded(_: Data?, _ newValue: Data?) {
        guard let data = newValue else { return }
        shareData = data
        shareFileName = store.selectedFile?.name ?? "file"
        showingShareSheet = true
    }

    private var fileActionsBinding: Binding<Bool> {
        Binding(
            get: { store.showingFileActions },
            set: { isPresented in
                if !isPresented {
                    closeFileActions()
                }
            }
        )
    }

    private var filePreviewBinding: Binding<Bool> {
        Binding(
            get: { store.showingFilePreview },
            set: { isPresented in
                if !isPresented {
                    store.send(.dismissPreview)
                }
            }
        )
    }

    private func closeFileActions() {
        store.send(.selectFile(nil))
    }

    private var selectionBanner: some View {
        StatusBannerView(
            style: .info,
            message: "\(store.selectedEntryPaths.count) selected",
            actionTitle: store.selectedEntryPaths.isEmpty ? nil : "Delete Selected",
            onDismiss: nil,
            onAction: store.selectedEntryPaths.isEmpty ? nil : {
                showingBatchDeleteConfirm = true
            }
        )
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var fileLoadingBanner: some View {
        if let file = store.selectedFile {
            StatusBannerView(
                style: .progress,
                message: "Loading \(file.name)...",
                showsProgress: true
            )
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}

struct FileListEntryView: View {
    let entry: FileEntry
    let isSelectionMode: Bool
    let isSelected: Bool
    let onOpen: (FileEntry) -> Void
    let onDownload: (FileEntry) -> Void
    let onDelete: (FileEntry) -> Void

    var body: some View {
        FileEntryRow(entry: entry, isSelectionMode: isSelectionMode, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen(entry)
            }
            .swipeActions(edge: .trailing) {
                if !isSelectionMode {
                    Button(role: .destructive) {
                        onDelete(entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    if !entry.isDirectory {
                        Button {
                            onDownload(entry)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .tint(.blue)
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
    var isSelectionMode: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

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

            if entry.isDirectory && !isSelectionMode {
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

struct FilePreviewSheet: View {
    let entry: FileEntry
    let data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var copiedText = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PreviewMetadataBar(entry: entry, data: data)

                Group {
                    if let image = UIImage(data: data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                        .background(Color.black.opacity(0.02))
                    } else if let text = previewText {
                        ScrollView {
                            Text(text)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                    } else {
                        ContentUnavailableView(
                            "Preview Unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("This file can be downloaded, but it cannot be previewed as text or image.")
                        )
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if let text = previewText {
                        Button {
                            UIPasteboard.general.string = text
                            copiedText = true
                        } label: {
                            Image(systemName: copiedText ? "checkmark.circle" : "doc.on.doc")
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 16) {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }

                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: copiedText) { _, isCopied in
                guard isCopied else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copiedText = false
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(data: data, fileName: entry.name)
            }
        }
    }

    private var previewText: String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }
}

struct PreviewMetadataBar: View {
    let entry: FileEntry
    let data: Data

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PreviewBadge(title: "Type", value: entry.isDirectory ? "Folder" : fileKind)
                PreviewBadge(title: "Size", value: entry.displaySize)
                PreviewBadge(title: "Modified", value: "\(entry.date) \(entry.time)")
                if let dimensions = imageDimensions {
                    PreviewBadge(title: "Image", value: dimensions)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var fileKind: String {
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    private var imageDimensions: String? {
        guard let image = UIImage(data: data) else { return nil }
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return "\(width)x\(height)"
    }
}

struct PreviewBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
