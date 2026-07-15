import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import ComposableArchitecture

enum FileManagerLayout {
    case compact
    case regular
}

struct FileManagerView: View {
    let store: StoreOf<FileManagerFeature>
    var focusRequestID = 0
    var layout = FileManagerLayout.compact
    @State private var isSearchPresented = false
    @State private var showingImportPicker = false
    @State private var showingDeleteConfirm = false
    @State private var entryToDelete: FileEntry?
    @State private var deleteConfirmation: DestructiveActionConfirmation?
    @State private var showingBatchDeleteConfirm = false
    @State private var batchDeleteConfirmation: DestructiveActionConfirmation?
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var showingBulkShareSheet = false

    var body: some View {
        NavigationStack {
            AnyView(navigationContent)
                .iadbWorkspaceWidth()
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: searchBinding,
                    isPresented: $isSearchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search Files"
                )
                .onChange(of: focusRequestID) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    isSearchPresented = false
                    DispatchQueue.main.async { isSearchPresented = true }
                }
                .toolbar(content: {
                    if store.isSelectionMode {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                store.send(.clearSelection)
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showingImportPicker = true
                        } label: {
                            Label("Upload", systemImage: "arrow.up.circle")
                        }
                        .accessibilityIdentifier("files.toolbar.upload")
                        .disabled(store.activeBackgroundOperationID != nil)

                        Menu {
                            Button {
                                store.send(.presentForm(.newFolder))
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                            Button {
                                store.send(.presentForm(.newTextFile))
                            } label: {
                                Label("New Text File", systemImage: "doc.badge.plus")
                            }
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .accessibilityIdentifier("files.toolbar.new")
                        .disabled(store.activeMutation != nil)

                        Button {
                            store.send(.toggleSelectionMode)
                        } label: {
                            Label(store.isSelectionMode ? "Done" : "Select", systemImage: store.isSelectionMode ? "checkmark.circle" : "checklist")
                        }
                        .accessibilityIdentifier("files.toolbar.select")
                    }
                })
                .navigationDestination(isPresented: compactFilePreviewBinding) {
                    filePreviewDestination
                }
        }
        .accessibilityIdentifier("workspace.files")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  store.activeBackgroundOperationID == nil else { return false }
            store.send(.reviewUpload(url: url, fileName: url.lastPathComponent))
            return true
        }
        .sheet(isPresented: operationFormBinding) {
            if let form = store.presentedForm {
                FileOperationFormView(
                    form: form,
                    destinationPaths: Array(Set(store.favorites + store.pathHistory)).sorted(),
                    onInputChanged: { store.send(.formInputChanged($0)) },
                    onCancel: { store.send(.dismissForm) },
                    onSubmit: { store.send(.submitForm) }
                )
                .iadbAdaptiveSheetHeight()
            }
        }
        .sheet(isPresented: uploadReviewBinding) {
            if let review = store.uploadReview {
                UploadReviewView(
                    review: review,
                    destinationPath: store.currentPath,
                    onPolicyChanged: { store.send(.setUploadConflictPolicy($0)) },
                    onCancel: { store.send(.dismissUploadReview) },
                    onConfirm: { store.send(.confirmUpload) }
                )
                .iadbAdaptiveSheetHeight()
            }
        }
        .confirmationDialog("Delete?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    store.send(.deleteFile(entry, confirmation: deleteConfirmation))
                }
            }
        } message: {
            Text(
                "Delete \(entryToDelete?.displayName ?? String(localized: "this item")) from \(store.remoteTarget.deviceName)?"
            )
        }
        .confirmationDialog("Delete Selected?", isPresented: $showingBatchDeleteConfirm) {
            Button("Delete", role: .destructive) {
                store.send(.deleteSelectedFiles(confirmation: batchDeleteConfirmation))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \(store.selectedEntryPaths.count) selected items from \(store.remoteTarget.deviceName)?")
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.send(.reviewUpload(url: url, fileName: url.lastPathComponent))
            case .failure(let error):
                store.send(.reportError(String(localized: "Could not import the file: \(error.localizedDescription)")))
            }
        }
        .onChange(of: store.downloadedFileURL, shareDownloadedFileIfNeeded)
        .onChange(of: store.downloadedFileURLs) { _, urls in
            showingBulkShareSheet = !urls.isEmpty
        }
        .sheet(isPresented: $showingShareSheet) {
            if let shareURL {
                ShareURLSheet(url: shareURL)
            }
        }
        .sheet(isPresented: $showingBulkShareSheet) {
            ShareURLsSheet(urls: store.downloadedFileURLs)
        }
        .onChange(of: showingShareSheet) { _, isPresented in
            if !isPresented {
                shareURL = nil
                store.send(.clearDownloadedFile)
            }
        }
        .onChange(of: showingBulkShareSheet) { _, isPresented in
            if !isPresented {
                store.send(.clearDownloadedFiles)
            }
        }
        .confirmationDialog(
            store.selectedFile?.displayName ?? String(localized: "File Actions"),
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
                    store.send(.presentForm(.rename(file)))
                }

                Button("Move") {
                    store.send(.presentForm(.move(file)))
                }

                Button("Duplicate") {
                    store.send(.duplicateFile(file))
                }

                Button("Copy Path") {
                    UIPasteboard.general.string = file.fullPath
                    announceAccessibility("File path copied")
                    closeFileActions()
                }

                Button("Delete", role: .destructive) {
                    confirmDelete(file)
                    closeFileActions()
                }
            }
        } message: {
            if let file = store.selectedFile {
                Text(file.fullPath)
            }
        }
    }

    @ViewBuilder
    private var filePreviewDestination: some View {
        if let file = store.selectedFile,
           store.previewFilePath == file.fullPath,
           let data = store.previewFileData {
            FilePreviewSheet(
                entry: file,
                data: data,
                isEmbeddedInNavigationStack: false
            ) { editedData, fileName in
                store.send(.pushFileData(data: editedData, fileName: fileName))
            }
            .accessibilityIdentifier("files.preview")
        } else {
            DetailInspector(state: .loading(title: "Loading preview…")) {
                EmptyView()
            }
        }
    }

    private var navigationContent: some View {
        VStack(spacing: 0) {
            if store.isDetailLoading, store.fileLoadPurpose == .preview {
                fileLoadingBanner
            }

            if let error = store.errorMessage, !store.entries.isEmpty {
                StatusBannerView(style: .error, message: error)
                    .padding(.horizontal)
                    .padding(.top, store.isDirectoryLoading ? 0 : 8)
                    .padding(.bottom, 8)
            } else if let summary = store.operationSummary, store.activeMutation == nil {
                StatusBannerView(
                    style: (store.bulkOperation?.failedCount ?? 0) > 0 ? .error : .success,
                    message: summary
                )
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            if let mutation = store.activeMutation {
                StatusBannerView(
                    style: .progress,
                    message: mutationMessage(mutation),
                    showsProgress: true
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else if store.isDirectoryLoading, !store.entries.isEmpty {
                StatusBannerView(
                    style: .progress,
                    message: String(localized: "Refreshing directory…"),
                    showsProgress: true
                )
                    .padding(.horizontal)
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
            .disabled(store.isDirectoryLoading)
            .accessibilityIdentifier("files.breadcrumb")

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
        BulkActionBar(
            selectionCount: store.selectedEntryPaths.count,
            selectionLabel: store.selectedEntryPaths.count == 1
                ? String(localized: "1 item")
                : String(localized: "\(store.selectedEntryPaths.count) items"),
            actions: [
                BulkActionItem(
                    id: "select-all",
                    title: "Select All",
                    symbol: "checkmark.circle",
                    emphasis: .secondary,
                    isEnabled: store.selectedEntryPaths.count < visibleEntries.count,
                    action: {
                        store.send(.selectAllVisible(visibleEntries.map(\.fullPath)))
                    }
                ),
                BulkActionItem(
                    id: "move",
                    title: "Move",
                    symbol: "folder",
                    emphasis: .secondary,
                    isEnabled: !store.selectedEntryPaths.isEmpty && store.activeMutation == nil,
                    action: {
                        let entries = store.entries.filter {
                            store.selectedEntryPaths.contains($0.fullPath)
                        }
                        store.send(.presentForm(.moveSelection(entries)))
                    }
                ),
                BulkActionItem(
                    id: "duplicate",
                    title: "Duplicate",
                    symbol: "plus.square.on.square",
                    emphasis: .secondary,
                    isEnabled: !store.selectedEntryPaths.isEmpty && store.activeMutation == nil,
                    action: { store.send(.duplicateSelectedFiles) }
                ),
                BulkActionItem(
                    id: "clear",
                    title: "Clear Selection",
                    symbol: nil,
                    emphasis: .secondary,
                    action: { store.send(.clearSelection) }
                ),
                BulkActionItem(
                    id: "download",
                    title: "Download",
                    symbol: "arrow.down.circle",
                    emphasis: .secondary,
                    isEnabled: store.entries.contains {
                        store.selectedEntryPaths.contains($0.fullPath) && !$0.isDirectory
                    } && store.activeBackgroundOperationID == nil,
                    action: { store.send(.downloadSelectedFiles) }
                ),
                BulkActionItem(
                    id: "delete",
                    title: "Delete",
                    symbol: "trash",
                    emphasis: .destructive,
                    isEnabled: !store.selectedEntryPaths.isEmpty,
                    action: confirmBatchDelete
                )
            ]
        )
    }

    private func showCurrentPathEditor() {
        store.send(.presentForm(.goToPath))
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.isDirectoryLoading && store.entries.isEmpty {
            loadingContent
        } else if store.errorMessage != nil && store.entries.isEmpty {
            errorContent
        } else if store.entries.isEmpty {
            emptyContent
        } else if layout == .regular {
            fileTable
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
                    store.send(.presentForm(.newFolder))
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
        List(visibleEntries) { entry in
            FileListEntryView(
                entry: entry,
                isSelectionMode: store.isSelectionMode,
                isSelected: store.selectedEntryPaths.contains(entry.fullPath),
                operationPhase: store.bulkOperation?.items.first(where: { $0.id == entry.fullPath })?.phase,
                onOpen: openEntry,
                onDownload: downloadEntry,
                onDelete: confirmDelete,
                onActions: { store.send(.selectFile($0)) }
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("files.list")
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            FileTableHeader(sort: store.sort) {
                store.send(.setSort($0))
            }
            Divider()
            List(visibleEntries) { entry in
                FileTableRow(
                    entry: entry,
                    isSelected: store.selectedFile?.fullPath == entry.fullPath,
                    isSelectionMode: store.isSelectionMode,
                    isBulkSelected: store.selectedEntryPaths.contains(entry.fullPath),
                    operationPhase: store.bulkOperation?.items.first(where: { $0.id == entry.fullPath })?.phase
                ) {
                    if store.isSelectionMode {
                        store.send(.toggleEntrySelection(entry))
                    } else if entry.isNavigableDirectory {
                        store.send(.navigateTo(entry))
                    } else {
                        let selection = store.selectedFile?.fullPath == entry.fullPath ? nil : entry
                        store.send(.selectInspector(selection))
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("files.table")
        }
    }

    private var visibleEntries: [FileEntry] {
        store.visibleEntries
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { store.searchQuery },
            set: { store.send(.setSearchQuery($0)) }
        )
    }

    private func openEntry(_ entry: FileEntry) {
        if store.isSelectionMode {
            store.send(.toggleEntrySelection(entry))
        } else if entry.isNavigableDirectory {
            store.send(.navigateTo(entry))
        } else {
            store.send(.selectFile(entry))
            if entry.isPreviewable {
                store.send(.previewSelectedFile)
            }
        }
    }

    private func downloadEntry(_ entry: FileEntry) {
        store.send(.selectFile(entry))
        store.send(.downloadSelectedFile)
    }

    private func confirmDelete(_ entry: FileEntry) {
        entryToDelete = entry
        deleteConfirmation = store.remoteTarget.confirmation(for: entry.fullPath)
        showingDeleteConfirm = true
    }

    private func confirmBatchDelete() {
        let objectID = FileManagerFeature.bulkOperationObjectID(
            paths: Array(store.selectedEntryPaths)
        )
        batchDeleteConfirmation = store.remoteTarget.confirmation(for: objectID)
        showingBatchDeleteConfirm = true
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

    private var compactFilePreviewBinding: Binding<Bool> {
        Binding(
            get: { layout == .compact && store.showingFilePreview },
            set: { isPresented in
                if !isPresented {
                    store.send(.dismissPreview)
                }
            }
        )
    }

    private var operationFormBinding: Binding<Bool> {
        Binding(
            get: { store.presentedForm != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.dismissForm)
                }
            }
        )
    }

    private var uploadReviewBinding: Binding<Bool> {
        Binding(
            get: { store.uploadReview != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.dismissUploadReview)
                }
            }
        )
    }

    private func closeFileActions() {
        store.send(.selectFile(nil))
    }

    private func mutationMessage(_ mutation: FileManagerFeature.MutationState) -> String {
        switch mutation.kind {
        case .create: String(localized: "Creating \(mutation.objectName)…")
        case .delete: String(localized: "Deleting \(mutation.objectName)…")
        case .duplicate: String(localized: "Duplicating \(mutation.objectName)…")
        case .move: String(localized: "Moving \(mutation.objectName)…")
        }
    }

    @ViewBuilder
    private var fileLoadingBanner: some View {
        if let file = store.selectedFile {
            StatusBannerView(
                style: .progress,
                message: String(localized: "Loading \(file.displayName)..."),
                showsProgress: true
            )
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}

private struct FileOperationFormView: View {
    let form: FileManagerFeature.FileOperationForm
    let destinationPaths: [String]
    let onInputChanged: (String) -> Void
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                if isMoveForm {
                    Section("Destination Browser") {
                        ForEach(destinationPaths, id: \.self) { path in
                            Button {
                                onInputChanged(destinationValue(for: path))
                            } label: {
                                Label(path, systemImage: "folder")
                                    .font(.body.monospaced())
                            }
                        }
                    }
                }
                Section {
                    InlineValidatedField(
                        localizedLabel: fieldTitle,
                        symbol: fieldSymbol,
                        validationMessage: form.validationMessage
                    ) {
                        TextField(fieldTitle, text: inputBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(submitIfValid)
                            .accessibilityIdentifier("files.operationForm.input")
                    }
                } header: {
                    Text(sectionTitle)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle, action: onSubmit)
                        .disabled(form.validationMessage != nil)
                        .accessibilityIdentifier("files.operationForm.submit")
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(false)
        .accessibilityIdentifier("files.operationForm")
    }

    private var inputBinding: Binding<String> {
        Binding(get: { form.input }, set: onInputChanged)
    }

    private var title: String {
        switch form.kind {
        case .newFolder: String(localized: "New Folder")
        case .newTextFile: String(localized: "New Text File")
        case .goToPath: String(localized: "Go to Path")
        case .rename: String(localized: "Rename")
        case .move, .moveSelection: String(localized: "Move")
        }
    }

    private var sectionTitle: String {
        switch form.kind {
        case .move, .moveSelection: String(localized: "Advanced Destination")
        case .goToPath: String(localized: "Remote Location")
        default: String(localized: "Name")
        }
    }

    private var fieldTitle: String {
        switch form.kind {
        case .newFolder: String(localized: "Folder name")
        case .newTextFile: String(localized: "File name")
        case .goToPath, .move, .moveSelection: String(localized: "Absolute path")
        case .rename: String(localized: "New name")
        }
    }

    private var fieldSymbol: String {
        switch form.kind {
        case .newFolder: "folder"
        case .newTextFile: "doc.text"
        case .goToPath, .move, .moveSelection: "point.topleft.down.to.point.bottomright.curvepath"
        case .rename: "pencil"
        }
    }

    private var footerText: String {
        switch form.kind {
        case .newFolder: String(localized: "Creates a folder in the current remote directory.")
        case .newTextFile: String(localized: "Creates an empty UTF-8 text file in the current remote directory.")
        case .goToPath: String(localized: "Enter an absolute Android path beginning with '/'.")
        case .rename(let entry): String(localized: "Renames \(entry.displayName) in its current directory.")
        case .move(let entry): String(localized: "Move \(entry.displayName) to an absolute Android path. The source remains unchanged if the destination already exists.")
        case .moveSelection(let entries): String(localized: "Move \(entries.count) selected items into an absolute Android directory. Each item reports its own result.")
        }
    }

    private var submitTitle: String {
        switch form.kind {
        case .newFolder, .newTextFile: String(localized: "Create")
        case .goToPath: String(localized: "Go")
        case .rename: String(localized: "Save")
        case .move, .moveSelection: String(localized: "Move")
        }
    }

    private var isMoveForm: Bool {
        switch form.kind {
        case .move, .moveSelection: true
        default: false
        }
    }

    private func destinationValue(for path: String) -> String {
        switch form.kind {
        case .move(let entry):
            return path.hasSuffix("/") ? "\(path)\(entry.name)" : "\(path)/\(entry.name)"
        case .moveSelection:
            return path
        default:
            return form.input
        }
    }

    private func submitIfValid() {
        guard form.validationMessage == nil else { return }
        onSubmit()
    }
}

private struct UploadReviewView: View {
    let review: FileManagerFeature.UploadReview
    let destinationPath: String
    let onPolicyChanged: (FileManagerFeature.UploadConflictPolicy) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: review.originalFileName)
                    if let totalBytes = review.totalBytes {
                        LabeledContent("Size", value: ByteCountFormatter.string(
                            fromByteCount: totalBytes,
                            countStyle: .file
                        ))
                    }
                    LabeledContent("Destination") {
                        Text(destinationPath)
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Target Device") {
                    LabeledContent("Device", value: review.target.deviceName)
                    LabeledContent(
                        "Status",
                        value: review.target.isConnected
                            ? String(localized: "Connected")
                            : String(localized: "Disconnected")
                    )
                }

                if review.hasConflict {
                    Section {
                        Picker("If the file exists", selection: policyBinding) {
                            Text("Replace").tag(FileManagerFeature.UploadConflictPolicy.replace)
                            Text("Keep Both").tag(FileManagerFeature.UploadConflictPolicy.keepBoth)
                            Text("Cancel").tag(FileManagerFeature.UploadConflictPolicy.cancel)
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text("Conflict Resolution")
                    } footer: {
                        Text("Replace removes the existing remote item only after this review is confirmed. Keep Both chooses a unique name.")
                    }
                }
            }
            .navigationTitle("Upload Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload", action: onConfirm)
                        .disabled(review.hasConflict && review.conflictPolicy == .cancel)
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .accessibilityIdentifier("files.uploadReview")
    }

    private var policyBinding: Binding<FileManagerFeature.UploadConflictPolicy> {
        Binding(get: { review.conflictPolicy }, set: onPolicyChanged)
    }
}

struct FileInspectorView: View {
    let store: StoreOf<FileManagerFeature>
    let file: FileEntry
    @State private var showingDeleteConfirmation = false
    @State private var deleteConfirmation: DestructiveActionConfirmation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                preview

                VStack(spacing: 0) {
                    TechnicalRow(label: "Name", value: file.displayName, allowsCopy: true)
                    Divider()
                    TechnicalRow(label: "Path", value: file.fullPath, monospacedValue: true, allowsCopy: true)
                    Divider()
                    TechnicalRow(label: "Size", value: file.displaySize)
                    Divider()
                    TechnicalRow(label: "Modified", value: "\(file.date) \(file.time)")
                    Divider()
                    TechnicalRow(label: "Permissions", value: file.permissions, monospacedValue: true, allowsCopy: true)
                    Divider()
                    TechnicalRow(label: "Owner", value: "\(file.owner):\(file.group)", monospacedValue: true)
                }

                actionSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger Zone")
                        .font(.headline)
                    Button(role: .destructive) {
                        deleteConfirmation = store.remoteTarget.confirmation(for: file.fullPath)
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete from \(store.remoteTarget.deviceName)", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.activeMutation != nil)
                }
            }
            .padding()
        }
        .navigationTitle("File Inspector")
        .confirmationDialog("Delete \(file.displayName)?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.send(.deleteFile(file, confirmation: deleteConfirmation))
                store.send(.selectInspector(nil))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the item from \(store.remoteTarget.deviceName).")
        }
        .accessibilityIdentifier("files.inspector")
    }

    @ViewBuilder
    private var preview: some View {
        if store.isDetailLoading, store.selectedFile?.fullPath == file.fullPath {
            DetailInspector(state: .loading(title: "Loading preview…")) {
                EmptyView()
            }
            .frame(minHeight: 180)
        } else if let data = store.previewFileData,
                  store.previewFilePath == file.fullPath {
            DetailInspector(state: .content) {
                FileInspectorPreview(data: data)
            }
            .frame(minHeight: 180)
        } else {
            DetailInspector(state: .empty(
                title: file.isPreviewable ? "Preview not loaded" : "Preview unavailable",
                message: file.isPreviewable
                    ? "Load a bounded local preview without leaving the file table."
                    : "Metadata and Download remain available for this file type.",
                symbol: file.isDirectory ? "folder" : "doc"
            )) {
                EmptyView()
            }
            .frame(minHeight: 180)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.headline)

            if file.isPreviewable {
                Button {
                    store.send(.previewSelectedFile)
                } label: {
                    Label("Load Preview", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isDetailLoading)
            }

            if !file.isDirectory {
                Button {
                    store.send(.downloadSelectedFile)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(store.activeBackgroundOperationID != nil)
            }

            Button {
                store.send(.presentForm(.rename(file)))
            } label: {
                Label("Rename", systemImage: "pencil")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(store.activeMutation != nil)

            Button {
                store.send(.presentForm(.move(file)))
            } label: {
                Label("Move", systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(store.activeMutation != nil)

            Button {
                store.send(.duplicateFile(file))
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(store.activeMutation != nil)
        }
    }
}

private struct FileInspectorPreview: View {
    let data: Data

    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else if let text = String(data: Data(data.prefix(256 * 1024)), encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        } else {
            ContentUnavailableView("Preview Unavailable", systemImage: "doc")
        }
    }
}

struct FileListEntryView: View {
    let entry: FileEntry
    let isSelectionMode: Bool
    let isSelected: Bool
    let operationPhase: FileManagerFeature.BulkOperationState.Item.Phase?
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
            .accessibilityLabel(entryAccessibilityLabel)
            .accessibilityValue(
                isSelectionMode
                    ? isSelected ? String(localized: "Selected") : String(localized: "Not selected")
                    : ""
            )
            .accessibilityHint(
                isSelectionMode
                    ? String(localized: "Selects this item")
                    : entry.isDirectory
                        ? String(localized: "Opens this folder")
                        : String(localized: "Shows item actions")
            )

            operationStatus

        }
        .frame(minHeight: 44)
        .iadbSelectionHighlight(isSelected: isSelectionMode && isSelected)
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
        .accessibilityAction(named: "Show item actions") {
            onActions(entry)
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        switch operationPhase {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Waiting to delete \(entry.displayName)")
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Deleting \(entry.displayName)")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Could not delete \(entry.displayName). \(message)")
        case .succeeded, nil:
            EmptyView()
        }
    }

    private var entryAccessibilityLabel: String {
        let type = entry.isDirectory
            ? String(localized: "Folder")
            : entry.isSymlink ? String(localized: "Link") : String(localized: "File")
        let size = entry.size.isEmpty ? String(localized: "size unavailable") : entry.displaySize
        return String(localized: "\(entry.displayName), \(type), \(size), modified \(entry.date) \(entry.time)")
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
                    .frame(width: IADBDesign.minimumHitTarget, height: IADBDesign.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Back")

            Button(action: onUp) {
                Image(systemName: "arrow.up")
                    .frame(width: IADBDesign.minimumHitTarget, height: IADBDesign.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoUp)
            .accessibilityLabel("Parent folder")

            Button(action: onPathTap) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.tint)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: IADBDesign.minimumHitTarget, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: IADBDesign.minimumHitTarget)
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
                sizeOnly
                Text("\(entry.date) \(entry.time)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                sizeOnly
                Text("\(entry.date) \(entry.time)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sizeOnly: some View {
        if !entry.size.isEmpty {
            Text(entry.displaySize)
        }
    }
}

private struct FileTableHeader: View {
    let sort: FileManagerFeature.FileSort
    let onSort: (FileManagerFeature.FileSort) -> Void

    var body: some View {
        HStack(spacing: 12) {
            sortButton("Name", width: nil, next: nameSort)
            sortButton("Size", width: 80, next: sizeSort)
            sortButton("Modified", width: 132, next: modifiedSort)
            sortButton("Permissions", width: 108, next: .permissions)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityIdentifier("files.table.header")
    }

    private func sortButton(
        _ title: String,
        width: CGFloat?,
        next: FileManagerFeature.FileSort
    ) -> some View {
        Button {
            onSort(next)
        } label: {
            HStack(spacing: 4) {
                Text(localizedSortTitle(title))
                if indicatesSort(title) {
                    Image(systemName: sortIndicator)
                }
            }
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("Sort by \(localizedSortTitle(title))")
    }

    private var nameSort: FileManagerFeature.FileSort {
        sort == .nameAscending ? .nameDescending : .nameAscending
    }

    private var sizeSort: FileManagerFeature.FileSort {
        sort == .sizeAscending ? .sizeDescending : .sizeAscending
    }

    private var modifiedSort: FileManagerFeature.FileSort {
        sort == .modifiedNewest ? .modifiedOldest : .modifiedNewest
    }

    private var sortIndicator: String {
        switch sort {
        case .nameDescending, .sizeDescending, .modifiedNewest: "chevron.down"
        default: "chevron.up"
        }
    }

    private func indicatesSort(_ title: String) -> Bool {
        switch (title, sort) {
        case ("Name", .nameAscending), ("Name", .nameDescending),
             ("Size", .sizeAscending), ("Size", .sizeDescending),
             ("Modified", .modifiedNewest), ("Modified", .modifiedOldest),
             ("Permissions", .permissions):
            true
        default:
            false
        }
    }

    private func localizedSortTitle(_ title: String) -> String {
        switch title {
        case "Name": String(localized: "Name")
        case "Size": String(localized: "Size")
        case "Modified": String(localized: "Modified")
        case "Permissions": String(localized: "Permissions")
        default: title
        }
    }
}

private struct FileTableRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let isSelectionMode: Bool
    let isBulkSelected: Bool
    let operationPhase: FileManagerFeature.BulkOperationState.Item.Phase?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    if isSelectionMode {
                        Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isBulkSelected ? Color.accentColor : .secondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: entry.iconName)
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    Text(entry.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    phaseIndicator
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.displaySize)
                    .frame(width: 80, alignment: .trailing)
                Text("\(entry.date) \(entry.time)")
                    .frame(width: 132, alignment: .leading)
                Text(entry.permissions)
                    .fontDesign(.monospaced)
                    .frame(width: 108, alignment: .leading)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .iadbSelectionHighlight(
            isSelected: isSelectionMode ? isBulkSelected : isSelected
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isSelectionMode
                ? isBulkSelected ? String(localized: "Selected") : String(localized: "Not selected")
                : isSelected ? String(localized: "Selected") : ""
        )
        .accessibilityHint(
            isSelectionMode
                ? String(localized: "Changes selection")
                : entry.isNavigableDirectory
                    ? String(localized: "Opens this folder")
                    : String(localized: "Shows file details")
        )
        .accessibilityAddTraits(
            (isSelectionMode ? isBulkSelected : isSelected) ? .isSelected : []
        )
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch operationPhase {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        case .succeeded, nil:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        let type = entry.isDirectory
            ? String(localized: "Folder")
            : entry.isSymlink ? String(localized: "Link") : String(localized: "File")
        let size = entry.size.isEmpty ? String(localized: "size unavailable") : entry.displaySize
        return String(localized: "\(entry.displayName), \(type), \(size), modified \(entry.date) \(entry.time), permissions \(entry.permissions)")
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

struct ShareURLsSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct FilePreviewSheet: View {
    let entry: FileEntry
    let data: Data
    let isEmbeddedInNavigationStack: Bool
    let onSaveAs: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var copiedText = false
    @State private var isEditing = false
    @State private var editableText: String
    @State private var showingSaveAs = false
    @State private var saveAsName: String

    init(
        entry: FileEntry,
        data: Data,
        isEmbeddedInNavigationStack: Bool = true,
        onSaveAs: @escaping (Data, String) -> Void = { _, _ in }
    ) {
        self.entry = entry
        self.data = data
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.onSaveAs = onSaveAs
        _editableText = State(initialValue: String(data: data, encoding: .utf8) ?? "")
        let path = entry.name as NSString
        let ext = path.pathExtension
        let base = path.deletingPathExtension
        _saveAsName = State(initialValue: ext.isEmpty ? "\(base) edited" : "\(base) edited.\(ext)")
    }

    var body: some View {
        Group {
            if isEmbeddedInNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            PreviewMetadataBar(entry: entry, data: data)

            DetailInspector(state: .content) {
                if let image = previewImage {
                    FileImagePreview(image: image)
                } else if isEditing {
                    TextEditor(text: $editableText)
                        .font(.caption.monospaced())
                        .padding(8)
                        .accessibilityLabel("Edit \(entry.displayName)")
                } else if let text = previewText {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .accessibilityElement()
                            .accessibilityLabel("File preview text")
                            .accessibilityValue(text)
                    }
                    .textSelection(.enabled)
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("This file can be downloaded, but it cannot be previewed as text or image.")
                    )
                }
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if supportsTextEditing {
                    Button(isEditing ? String(localized: "Preview") : String(localized: "Edit")) {
                        isEditing.toggle()
                    }
                    .accessibilityLabel(
                        isEditing
                            ? String(localized: "Stop editing and preview")
                            : String(localized: "Edit text")
                    )
                }
                if let text = previewText {
                    Button {
                        UIPasteboard.general.string = text
                        copiedText = true
                        announceAccessibility("Preview text copied")
                    } label: {
                        Image(systemName: copiedText ? "checkmark.circle" : "doc.on.doc")
                    }
                    .accessibilityLabel(
                        copiedText ? String(localized: "Copied text") : String(localized: "Copy preview text")
                    )
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 16) {
                    if isEditing, isDirty {
                        Button("Save As") {
                            showingSaveAs = true
                        }
                    }
                    Button {
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share file")

                    if isEmbeddedInNavigationStack {
                        Button("Done") {
                            dismiss()
                        }
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
        .sheet(isPresented: $showingSaveAs) {
            TextEditSaveAsView(
                fileName: $saveAsName,
                onCancel: { showingSaveAs = false },
                onSave: {
                    guard let editedData = editableText.data(using: .utf8) else { return }
                    onSaveAs(editedData, saveAsName)
                    showingSaveAs = false
                }
            )
        }
    }

    private var supportsTextEditing: Bool {
        data.count <= 512 * 1024 && String(data: data, encoding: .utf8) != nil
    }

    private var isDirty: Bool {
        editableText.data(using: .utf8) != data
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

private struct FileImagePreview: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: max(proxy.size.width, 1) * displayedScale)
                        .frame(minHeight: proxy.size.height)
                }
                .contentMargins(12, for: .scrollContent)
                .gesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            scale = clamped(scale * value)
                        }
                )
                .accessibilityLabel("Image preview")
                .accessibilityValue("Zoom \(zoomPercentage) percent")
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    scale = clamped(scale - 0.25)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                        .frame(minHeight: 44)
                }
                .disabled(scale <= 1)

                Text("\(zoomPercentage)%")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 56)
                    .accessibilityHidden(true)

                Button {
                    scale = clamped(scale + 0.25)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                        .frame(minHeight: 44)
                }
                .disabled(scale >= 4)

                Button("Fit") {
                    scale = 1
                }
                .frame(minHeight: 44)
                .disabled(scale == 1)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .background(Color.black.opacity(0.02))
    }

    private var displayedScale: CGFloat {
        clamped(scale * gestureScale)
    }

    private var zoomPercentage: Int {
        Int((displayedScale * 100).rounded())
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 4)
    }
}

private struct TextEditSaveAsView: View {
    @Binding var fileName: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InlineValidatedField(
                        "File name",
                        symbol: "doc.text",
                        validationMessage: validationMessage
                    ) {
                        TextField("File name", text: $fileName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Save As writes a new bounded UTF-8 file. The original remains unchanged.")
                }
            }
            .navigationTitle("Save Text As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(validationMessage != nil)
                }
            }
        }
    }

    private var validationMessage: String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Name cannot be empty.") }
        if fileName.contains("/") || fileName.contains("\0") {
            return String(localized: "Enter a valid file name.")
        }
        return nil
    }
}

struct PreviewMetadataBar: View {
    let entry: FileEntry
    let data: Data
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.displayName)
                .font(.headline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("File name, \(spokenFileName)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("files.preview.name")

            LazyVGrid(columns: metadataColumns, alignment: .leading, spacing: 8) {
                PreviewBadge(
                    title: "Type",
                    value: entry.isDirectory ? String(localized: "Folder") : fileKind
                )
                PreviewBadge(title: "Size", value: entry.displaySize)
                PreviewBadge(title: "Modified", value: "\(entry.date) \(entry.time)")
                if let dimensions = imageDimensions {
                    PreviewBadge(title: "Image", value: dimensions)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var metadataColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .leading)]
        }
        return [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)]
    }

    private var fileKind: String {
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? String(localized: "File") : ext.uppercased()
    }

    private var spokenFileName: String {
        entry.displayName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " dot ")
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

    init(title: LocalizedStringResource, value: String) {
        self.title = String(localized: title)
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
