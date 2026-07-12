import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
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
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            AnyView(navigationContent)
                .iadbContentWidth()
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(content: {
                    if store.isSelectionMode {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                store.send(.clearSelection)
                            }
                        }
                    }
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
                        .accessibilityLabel("File actions")
                        .disabled(store.isLoading)
                    }
                })
        }
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
                Text("Move \(entry.displayName) to a new absolute path")
            }
        }
        .confirmationDialog("Delete?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    store.send(.deleteFile(entry))
                }
            }
        } message: {
            Text("Delete \(entryToDelete?.displayName ?? "this item")?")
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
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.send(.pushFile(url: url, fileName: url.lastPathComponent))
            case .failure(let error):
                store.send(.reportError("Could not import the file: \(error.localizedDescription)"))
            }
        }
        .onChange(of: store.downloadedFileURL, shareDownloadedFileIfNeeded)
        .sheet(isPresented: $showingShareSheet) {
            if let shareURL {
                ShareURLSheet(url: shareURL)
            }
        }
        .onChange(of: showingShareSheet) { _, isPresented in
            if !isPresented {
                shareURL = nil
                store.send(.clearDownloadedFile)
            }
        }
        .confirmationDialog(
            store.selectedFile?.displayName ?? "File Actions",
            isPresented: fileActionsBinding,
            titleVisibility: .visible
        ) {
            if let file = store.selectedFile {
                if file.isSymlink {
                    Button("Open Link as Folder") {
                        store.send(.navigateTo(file))
                    }
                }

                Button("Preview") {
                    store.send(.previewSelectedFile)
                }
                .disabled(!file.isPreviewable)

                if !file.isDirectory {
                    Button("Download") {
                        store.send(.downloadSelectedFile)
                    }
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

            if let error = store.errorMessage, !store.entries.isEmpty {
                StatusBannerView(style: .error, message: error)
                    .padding(.horizontal)
                    .padding(.top, store.isLoading ? 0 : 8)
                    .padding(.bottom, 8)
            }

            PathBar(
                path: store.currentPath,
                canGoBack: store.pathHistory.count > 1,
                canGoUp: store.currentPath != "/",
                onBack: { store.send(.goBack) },
                onUp: { store.send(.navigateUp) },
                onPathTap: showCurrentPathEditor
            )
            .disabled(store.isLoading)

            mainContent
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.isSelectionMode {
                selectionBar
            }
        }
    }

    private var selectionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                selectionSummary
                    .fixedSize(horizontal: true, vertical: true)

                Spacer(minLength: 8)

                Button {
                    store.send(.clearSelection)
                } label: {
                    Text("Clear Selection")
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showingBatchDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(store.selectedEntryPaths.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                selectionSummary

                Button {
                    store.send(.clearSelection)
                } label: {
                    Text("Clear Selection")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showingBatchDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(store.selectedEntryPaths.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(store.selectedEntryPaths.count) items")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func showCurrentPathEditor() {
        pathInput = store.currentPath
        showingPathInput = true
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.isLoading && store.entries.isEmpty {
            loadingContent
        } else if store.errorMessage != nil && store.entries.isEmpty {
            errorContent
        } else if store.entries.isEmpty {
            emptyContent
        } else {
            entriesList
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView("Loading...")
            Button("Cancel") {
                store.send(.cancelCurrentOperation)
            }
            .buttonStyle(.bordered)
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
            if let message = store.errorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
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
            Text("Create a folder or upload a file to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showingImportPicker = true
                } label: {
                    Label("Upload", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
            }
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
                onDelete: confirmDelete,
                onActions: { store.send(.selectFile($0)) }
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func openEntry(_ entry: FileEntry) {
        store.send(.navigateTo(entry))
    }

    private func downloadEntry(_ entry: FileEntry) {
        store.send(.selectFile(entry))
        store.send(.downloadSelectedFile)
    }

    private func confirmDelete(_ entry: FileEntry) {
        entryToDelete = entry
        showingDeleteConfirm = true
    }

    private func shareDownloadedFileIfNeeded(_: URL?, _ newValue: URL?) {
        guard let url = newValue else { return }
        shareURL = url
        showingShareSheet = true
    }

    private var fileActionsBinding: Binding<Bool> {
        Binding(
            get: { store.showingFileActions },
            set: { isPresented in
                // Action reducers dismiss the dialog before their async work
                // starts. Preserve the selected file in that case so preview
                // and download destinations still have their source context.
                if !isPresented, store.showingFileActions {
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

    @ViewBuilder
    private var fileLoadingBanner: some View {
        if let file = store.selectedFile {
            StatusBannerView(
                style: .progress,
                message: "Loading \(file.displayName)...",
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
    let onActions: (FileEntry) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onOpen(entry)
            } label: {
                FileEntryRow(
                    entry: entry,
                    isSelectionMode: isSelectionMode,
                    isSelected: isSelected
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(entry.isDirectory ? "Folder \(entry.displayName)" : entry.isSymlink ? "Link \(entry.displayName)" : "File \(entry.displayName)")
            .accessibilityHint(isSelectionMode ? "Selects this item" : entry.isDirectory ? "Opens this folder" : "Shows item actions")

            if !isSelectionMode {
                Button {
                    onActions(entry)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Actions for \(entry.displayName)")
            }
        }
        .contextMenu {
            if !isSelectionMode {
                Button {
                    onActions(entry)
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }

                if !entry.isDirectory {
                    Button {
                        onDownload(entry)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }

                Button(role: .destructive) {
                    onDelete(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
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
    let canGoUp: Bool
    let onBack: () -> Void
    let onUp: () -> Void
    let onPathTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!canGoBack)
            .accessibilityLabel("Back")

            Button(action: onUp) {
                Image(systemName: "arrow.up")
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!canGoUp)
            .accessibilityLabel("Parent folder")

            Button(action: onPathTap) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.tint)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("Current path \(path). Double-tap to edit.")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                Text(entry.displayName)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                metadata
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

    @ViewBuilder
    private var metadata: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                sizeAndPermissions
                Text("\(entry.date) \(entry.time)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                sizeAndPermissions
                Text("\(entry.date) \(entry.time)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var sizeAndPermissions: some View {
        HStack(spacing: 8) {
            if !entry.size.isEmpty {
                Text(entry.displaySize)
            }
            Text(entry.permissions)
                .fontDesign(.monospaced)
        }
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

struct ShareURLSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
                    if let image = previewImage {
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
            .navigationTitle(entry.displayName)
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
                        .accessibilityLabel(copiedText ? "Copied text" : "Copy preview text")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 16) {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share file")

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
        let maximumTextBytes = 512 * 1024
        let wasTruncated = data.count > maximumTextBytes
        let bounded = Data(data.prefix(maximumTextBytes))
        guard var text = String(data: bounded, encoding: .utf8)
            ?? String(data: bounded, encoding: .utf16)
            ?? String(data: bounded, encoding: .ascii) else { return nil }
        if wasTruncated {
            text += "\n\n… Preview truncated at 512 KiB. Download the file to view all content."
        }
        return text
    }

    private var previewImage: UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let pixelWidth = width.int64Value
        let pixelHeight = height.int64Value
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= 16_384,
              pixelHeight <= 16_384,
              pixelWidth <= 40_000_000 / pixelHeight else { return nil }
        return UIImage(data: data)
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return "\(width.intValue)x\(height.intValue)"
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
