import SwiftUI
import UniformTypeIdentifiers
import ComposableArchitecture

enum AppsLayout {
    case compact
    case regular
}

struct AppsView: View {
    @Bindable var store: StoreOf<AppsFeature>
    let focusRequestID: Int
    let layout: AppsLayout
    @State private var showingImportPicker = false
    @State private var showingFilters = false
    @State private var showingBulkUninstallReview = false
    @State private var bulkUninstallConfirmation: DestructiveActionConfirmation?
    @State private var isSearchPresented = false
    @State private var showingUninstallConfirm = false
    @State private var appToUninstall: AppInfo?
    @State private var uninstallConfirmation: DestructiveActionConfirmation?
    @State private var showingClearDataConfirm = false
    @State private var appToClearData: AppInfo?
    @State private var clearDataConfirmation: DestructiveActionConfirmation?
    @State private var showingForceStopConfirm = false
    @State private var appToForceStop: AppInfo?
    private var packageSummary: String {
        let count = store.apps.count
        return count == 1
            ? String(localized: "1 package on device")
            : String(localized: "\(count) packages on device")
    }

    private var resultSummary: String {
        let count = store.filteredApps.count
        return count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
    }

    init(
        store: StoreOf<AppsFeature>,
        focusRequestID: Int = 0,
        layout: AppsLayout = .compact
    ) {
        self.store = store
        self.focusRequestID = focusRequestID
        self.layout = layout
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                statusArea
                content
            }
            .iadbWorkspaceWidth()
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.isSelectionMode { bulkActionBar }
            }
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $store.searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search apps"
            )
            .onChange(of: focusRequestID) { oldValue, newValue in
                guard oldValue != newValue else { return }
                isSearchPresented = true
            }
            .confirmationDialog("Uninstall App?", isPresented: $showingUninstallConfirm) {
                Button("Uninstall", role: .destructive) {
                    if let app = appToUninstall {
                        store.send(.uninstall(
                            app,
                            keepData: false,
                            confirmation: uninstallConfirmation
                        ))
                    }
                }
                Button("Uninstall and Keep Data", role: .destructive) {
                    if let app = appToUninstall {
                        store.send(.uninstall(
                            app,
                            keepData: true,
                            confirmation: uninstallConfirmation
                        ))
                    }
                }
            } message: {
                Text("Uninstall \(appToUninstall?.packageName ?? "") from \(store.remoteTarget.deviceName)?")
            }
            .confirmationDialog("Clear App Data?", isPresented: $showingClearDataConfirm) {
                Button("Clear Data", role: .destructive) {
                    if let app = appToClearData {
                        store.send(.clearData(app, confirmation: clearDataConfirmation))
                    }
                }
            } message: {
                Text("This erases all data and cache for \(appToClearData?.packageName ?? "") on \(store.remoteTarget.deviceName). The app will behave as if freshly installed.")
            }
            .confirmationDialog("Force Stop App?", isPresented: $showingForceStopConfirm) {
                Button("Force Stop", role: .destructive) {
                    if let app = appToForceStop {
                        store.send(.forceStop(app))
                    }
                }
            } message: {
                Text("Stop \(appToForceStop?.packageName ?? "")? Unsaved work in the app may be lost.")
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                    store.send(.reviewAPKFile(
                        url: url,
                        fileName: url.lastPathComponent,
                        totalBytes: values?.fileSize.map(Int64.init)
                    ))
                case .failure(let error):
                    store.send(.importFailed("Could not import the APK: \(error.localizedDescription)"))
                }
            }
            .sheet(isPresented: $store.showingAppDetail) {
                AppDetailSheet(
                    store: store,
                    app: store.selectedApp,
                    detail: store.appDetail,
                    rawDetail: store.appDetailText
                )
                .iadbAdaptiveSheetHeight()
            }
            .sheet(isPresented: installReviewBinding) {
                if let review = store.installReview {
                    APKInstallReviewView(
                        review: review,
                        canConfirm: review.target == store.remoteTarget && review.target.isConnected,
                        onReplaceChanged: { store.send(.setInstallReplaceExisting($0)) },
                        onGrantPermissionsChanged: { store.send(.setInstallGrantRuntimePermissions($0)) },
                        onAllowTestPackagesChanged: { store.send(.setInstallAllowTestPackages($0)) },
                        onCancel: { store.send(.dismissInstallReview) },
                        onConfirm: { store.send(.confirmInstallReview) }
                    )
                    .iadbAdaptiveSheetHeight()
                }
            }
            .sheet(isPresented: $showingFilters) {
                AppsFilterSheet(
                    filter: store.filter,
                    sort: store.sort,
                    onFilterChanged: { store.send(.setFilter($0)) },
                    onSortChanged: { store.send(.setSort($0)) }
                )
                .iadbAdaptiveSheetHeight()
            }
            .sheet(isPresented: $showingBulkUninstallReview) {
                BulkUninstallReviewView(
                    apps: selectedApps,
                    deviceName: store.remoteTarget.deviceName,
                    onCancel: {
                        showingBulkUninstallReview = false
                        bulkUninstallConfirmation = nil
                    },
                    onConfirm: {
                        store.send(.uninstallSelected(confirmation: bulkUninstallConfirmation))
                        showingBulkUninstallReview = false
                        bulkUninstallConfirmation = nil
                    }
                )
                .iadbAdaptiveSheetHeight()
            }
        }
    }

    private var filterToolbarTitle: String {
        String(localized: "Filters, \(store.filter.localizedTitle), sorted by \(store.sort.localizedTitle)")
    }

    private var selectedApps: [AppInfo] {
        store.apps.filter { store.selectedPackageNames.contains($0.packageName) }
    }

    private var bulkActionBar: some View {
        BulkActionBar(
            selectionCount: store.selectedPackageNames.count,
            selectionLabel: store.selectedPackageNames.count == 1
                ? String(localized: "1 app")
                : String(localized: "\(store.selectedPackageNames.count) apps"),
            actions: [
                BulkActionItem(
                    id: "select-all",
                    title: "Select All User Apps",
                    symbol: "checkmark.circle",
                    emphasis: .secondary,
                    isEnabled: store.selectedPackageNames.count < store.filteredApps.count(where: { !$0.isSystemApp }),
                    action: { store.send(.selectAllVisible(store.filteredApps)) }
                ),
                BulkActionItem(
                    id: "clear",
                    title: "Clear Selection",
                    symbol: nil,
                    emphasis: .secondary,
                    action: { store.send(.clearSelection) }
                ),
                BulkActionItem(
                    id: "uninstall",
                    title: "Uninstall",
                    symbol: "trash",
                    emphasis: .destructive,
                    isEnabled: !store.selectedPackageNames.isEmpty && store.bulkUninstall?.isActive != true,
                    action: stageBulkUninstall
                )
            ]
        )
    }

    private func stageBulkUninstall() {
        let packages = selectedApps.map(\.packageName)
        bulkUninstallConfirmation = store.remoteTarget.confirmation(
            for: AppsFeature.bulkUninstallObjectID(packages: packages)
        )
        showingBulkUninstallReview = true
    }

    private var installReviewBinding: Binding<Bool> {
        Binding(
            get: { store.installReview != nil },
            set: { isPresented in
                if !isPresented { store.send(.dismissInstallReview) }
            }
        )
    }

    private var controls: some View {
        WorkspaceToolbar {
            librarySummary
        } actions: {
            HStack(spacing: 8) {
                installButton

                Button {
                    showingFilters = true
                } label: {
                    Label(filterToolbarTitle, systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("apps.filter")

                Button {
                    store.send(.toggleSelectionMode)
                } label: {
                    Label(store.isSelectionMode ? "Done" : "Select", systemImage: "checklist")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("apps.select")

                Button {
                    store.send(.loadApps)
                } label: {
                    Label("Reload apps", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(store.isLoading)
                .accessibilityHint("Fetches the installed package list again")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var librarySummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Installed Apps")
                .font(.headline)
            Text(packageSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var installButton: some View {
        Button {
            showingImportPicker = true
        } label: {
            Label("Install APK", systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .disabled(store.isInstalling)
        .accessibilityHint("Choose an Android package file to install")
        .accessibilityIdentifier("apps.primary.install")
    }

    @ViewBuilder
    private var statusArea: some View {
        if store.statusMessage != nil || store.isInstalling || store.hasActiveOperations ||
            store.bulkUninstall != nil || store.bulkResultSummary != nil ||
            (store.isLoading && !store.apps.isEmpty) ||
            store.isLoadingDetail || store.errorMessage != nil {
            VStack(spacing: 8) {
                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: store.apps.isEmpty ? String(localized: "Retry") : nil,
                        onDismiss: { store.send(.dismissError) },
                        onAction: store.apps.isEmpty ? { store.send(.loadApps) } : nil
                    )
                }

                if store.isInstalling {
                    StatusBannerView(
                        style: .progress,
                        message: store.installProgress,
                        showsProgress: true,
                        actionTitle: String(localized: "Cancel"),
                        onAction: { store.send(.cancelInstall) }
                    )
                }

                if store.isLoading, !store.apps.isEmpty {
                    StatusBannerView(
                        style: .progress,
                        message: String(localized: "Refreshing installed apps…"),
                        showsProgress: true
                    )
                }

                if let bulk = store.bulkUninstall, bulk.isActive {
                    StatusBannerView(
                        style: .progress,
                        message: String(localized: "Uninstalling apps, \(bulk.completedCount) of \(bulk.items.count) processed…"),
                        showsProgress: true,
                        actionTitle: String(localized: "Cancel"),
                        onAction: { store.send(.cancelBulkUninstall) }
                    )
                } else if let summary = store.bulkResultSummary {
                    StatusBannerView(
                        style: (store.bulkUninstall?.failedCount ?? 0) > 0 ? .error : .success,
                        message: summary
                    )
                }

                ForEach(store.operationsByPackage.values.sorted(by: { $0.packageName < $1.packageName }), id: \.id) { operation in
                    StatusBannerView(
                        style: .progress,
                        message: operation.message,
                        showsProgress: true,
                        actionTitle: String(localized: "Cancel"),
                        onAction: { store.send(.cancelOperation(packageName: operation.packageName)) }
                    )
                }

                if store.isLoadingDetail {
                    StatusBannerView(
                        style: .progress,
                        message: String(localized: "Loading app details…"),
                        showsProgress: true
                    )
                }

                if let status = store.statusMessage {
                    StatusBannerView(
                        style: .success,
                        message: status,
                        onDismiss: { store.send(.dismissStatus) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.apps.isEmpty {
            AppsLoadingView()
        } else if store.filteredApps.isEmpty {
            emptyState
        } else if layout == .regular {
            appTable
        } else {
            List {
                Section {
                    ForEach(store.filteredApps) { app in
                        AppRow(
                            app: app,
                            isSelectionMode: store.isSelectionMode,
                            isSelected: store.selectedPackageNames.contains(app.packageName),
                            operation: store.operationsByPackage[app.packageName],
                            bulkPhase: store.bulkUninstall?.items.first(where: { $0.id == app.packageName })?.phase,
                            onDetails: {
                                if store.isSelectionMode {
                                    store.send(.togglePackageSelection(app))
                                } else {
                                    store.send(.getAppDetail(app))
                                }
                            },
                            onForceStop: {
                                appToForceStop = app
                                showingForceStopConfirm = true
                            },
                            onClearData: {
                                stageClearData(app)
                            },
                            onUninstall: {
                                stageUninstall(app)
                            }
                        )
                        .disabled(store.operationsByPackage[app.packageName] != nil)
                        .contextMenu {
                            if !store.isSelectionMode { appActions(for: app) }
                        }
                        .swipeActions(edge: .trailing) {
                            if !store.isSelectionMode {
                                Button(role: .destructive) {
                                    stageUninstall(app)
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                                .accessibilityLabel("Uninstall \(app.displayName)")
                            }
                        }
                    }
                } header: {
                    Text(resultSummary)
                        .textCase(nil)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(resultSummary) shown")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("apps.list")
            .scrollContentBackground(.hidden)
        }
    }

    private var appTable: some View {
        VStack(spacing: 0) {
            AppsTableHeader(sort: store.sort) {
                store.send(.setSort($0))
            }
            Divider()
            List(store.filteredApps) { app in
                AppsTableRow(
                    app: app,
                    isSelected: store.selectedApp?.packageName == app.packageName,
                    isSelectionMode: store.isSelectionMode,
                    isBulkSelected: store.selectedPackageNames.contains(app.packageName),
                    operation: store.operationsByPackage[app.packageName],
                    bulkPhase: store.bulkUninstall?.items.first(where: { $0.id == app.packageName })?.phase
                ) {
                    if store.isSelectionMode {
                        store.send(.togglePackageSelection(app))
                    } else {
                        let selection = store.selectedApp?.packageName == app.packageName ? nil : app
                        store.send(.selectInspector(selection))
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("apps.table")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                store.searchText.isEmpty
                    ? String(localized: "No Apps to Show")
                    : String(localized: "No Matching Apps"),
                systemImage: store.searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass"
            )
        } description: {
            if !store.searchText.isEmpty {
                Text("No app names or package identifiers match “\(store.searchText)”.")
            } else if store.apps.isEmpty {
                Text("Reload installed apps, or install an APK to get started.")
            } else {
                Text("No packages match the \(store.filter.localizedTitle.lowercased()) filter.")
            }
        } actions: {
            if !store.searchText.isEmpty {
                Button("Clear Search") {
                    store.send(.binding(.set(\.searchText, "")))
                }
                .buttonStyle(.borderedProminent)
            } else if !store.apps.isEmpty, store.filter != .all {
                Button("Show All Apps") {
                    store.send(.setFilter(.all))
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Reload") {
                    store.send(.loadApps)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func appActions(for app: AppInfo) -> some View {
        Button {
            store.send(.getAppDetail(app))
        } label: {
            Label("View Details", systemImage: "info.circle")
        }

        Button {
            appToForceStop = app
            showingForceStopConfirm = true
        } label: {
            Label("Force Stop", systemImage: "stop.circle")
        }

        Button(role: .destructive) {
            stageClearData(app)
        } label: {
            Label("Clear Data", systemImage: "eraser")
        }

        Divider()

        Button(role: .destructive) {
            stageUninstall(app)
        } label: {
            Label("Uninstall", systemImage: "trash")
        }
    }

    private func stageUninstall(_ app: AppInfo) {
        appToUninstall = app
        uninstallConfirmation = store.remoteTarget.confirmation(for: app.packageName)
        showingUninstallConfirm = true
    }

    private func stageClearData(_ app: AppInfo) {
        appToClearData = app
        clearDataConfirmation = store.remoteTarget.confirmation(for: app.packageName)
        showingClearDataConfirm = true
    }
}

private struct AppsFilterSheet: View {
    let filter: AppsFeature.AppFilter
    let sort: AppsFeature.AppSort
    let onFilterChanged: (AppsFeature.AppFilter) -> Void
    let onSortChanged: (AppsFeature.AppSort) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Packages") {
                    Picker("Package type", selection: filterBinding) {
                        ForEach(AppsFeature.AppFilter.allCases, id: \.self) {
                            Text($0.localizedTitle).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Sort") {
                    Picker("Sort apps", selection: sortBinding) {
                        ForEach(AppsFeature.AppSort.allCases, id: \.self) {
                            Text($0.localizedTitle).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Filter Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .accessibilityIdentifier("apps.filterSheet")
    }

    private var filterBinding: Binding<AppsFeature.AppFilter> {
        Binding(get: { filter }, set: onFilterChanged)
    }

    private var sortBinding: Binding<AppsFeature.AppSort> {
        Binding(get: { sort }, set: onSortChanged)
    }
}

private struct BulkUninstallReviewView: View {
    let apps: [AppInfo]
    let deviceName: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Target Device") {
                    LabeledContent("Device", value: deviceName)
                    LabeledContent("Packages", value: "\(apps.count)")
                }

                Section {
                    ForEach(apps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.displayName)
                            Text(app.packageName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("User Apps to Uninstall")
                } footer: {
                    Text("System apps are excluded. Each package is uninstalled separately so partial failures remain visible.")
                }
            }
            .navigationTitle("Review Uninstall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Uninstall", role: .destructive, action: onConfirm)
                        .disabled(apps.isEmpty)
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .accessibilityIdentifier("apps.bulkUninstallReview")
    }
}

private struct APKInstallReviewView: View {
    let review: AppsFeature.InstallReview
    let canConfirm: Bool
    let onReplaceChanged: (Bool) -> Void
    let onGrantPermissionsChanged: (Bool) -> Void
    let onAllowTestPackagesChanged: (Bool) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("APK") {
                    LabeledContent("File", value: review.fileName)
                    LabeledContent("Size", value: formattedSize)
                }

                Section("Target Device") {
                    LabeledContent("Device", value: review.target.deviceName)
                    LabeledContent(
                        "Status",
                        value: canConfirm ? String(localized: "Connected") : String(localized: "Target changed")
                    )
                }

                Section {
                    Toggle("Replace existing app", isOn: replaceBinding)
                    LabeledContent(
                        "Existing app data",
                        value: review.replaceExisting ? String(localized: "Kept") : String(localized: "Not applicable")
                    )
                } footer: {
                    Text("Replace uses Android's reinstall mode. Android keeps existing app data during a compatible update.")
                }

                Section("Advanced Install Flags") {
                    Toggle("Grant runtime permissions", isOn: permissionsBinding)
                    Text("Requests all runtime permissions declared by the APK after installation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Allow test packages", isOn: testPackagesBinding)
                    Text("Allows APKs marked testOnly. Leave off unless the package requires it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Install APK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install", action: onConfirm)
                        .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .accessibilityIdentifier("apps.installReview")
    }

    private var formattedSize: String {
        guard let totalBytes = review.totalBytes else { return String(localized: "Unavailable") }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private var replaceBinding: Binding<Bool> {
        Binding(get: { review.replaceExisting }, set: onReplaceChanged)
    }

    private var permissionsBinding: Binding<Bool> {
        Binding(get: { review.grantRuntimePermissions }, set: onGrantPermissionsChanged)
    }

    private var testPackagesBinding: Binding<Bool> {
        Binding(get: { review.allowTestPackages }, set: onAllowTestPackagesChanged)
    }
}

private struct AppsLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 5) {
                Text("Loading Installed Apps")
                    .font(.headline)
                Text("Reading user and system apps from the connected device…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading installed apps")
    }
}

private struct AppsTableHeader: View {
    let sort: AppsFeature.AppSort
    let onSort: (AppsFeature.AppSort) -> Void

    var body: some View {
        HStack(spacing: 12) {
            sortButton("App", value: .name)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            sortButton("Package", value: .package)
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            Text("Type")
                .frame(width: 90, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .accessibilityIdentifier("apps.table.header")
    }

    private func sortButton(_ title: LocalizedStringResource, value: AppsFeature.AppSort) -> some View {
        Button {
            onSort(value)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sort == value {
                    Image(systemName: "chevron.up")
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(String(localized: title))")
        .accessibilityValue(sort == value ? String(localized: "Selected") : "")
    }
}

private struct AppsTableRow: View {
    let app: AppInfo
    let isSelected: Bool
    let isSelectionMode: Bool
    let isBulkSelected: Bool
    let operation: AppsFeature.ActiveOperation?
    let bulkPhase: AppsFeature.BulkUninstallState.Item.Phase?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    if isSelectionMode {
                        Image(systemName: app.isSystemApp ? "lock.circle" : isBulkSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(app.isSystemApp ? .secondary : isBulkSelected ? Color.accentColor : .secondary)
                            .frame(width: 32, height: 44)
                    }
                    AppGlyph(isSystemApp: app.isSystemApp)
                        .scaleEffect(0.86)
                        .frame(width: 38, height: 38)
                    Text(app.displayName)
                        .lineLimit(1)
                }
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

                Text(app.packageName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(app.isSystemApp ? String(localized: "System") : String(localized: "User"))
                    if operation != nil || bulkPhase == .running {
                        ProgressView().controlSize(.small)
                    } else if case .failed = bulkPhase {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 90, alignment: .leading)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iadbSelectionHighlight(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(app.displayName), \(app.packageName), \(app.isSystemApp ? String(localized: "system") : String(localized: "user")) app"
        )
        .accessibilityValue(
            isSelectionMode
                ? app.isSystemApp
                    ? String(localized: "Unavailable for bulk uninstall")
                    : isBulkSelected ? String(localized: "Selected") : String(localized: "Not selected")
                : isSelected ? String(localized: "Selected") : operation?.message ?? ""
        )
    }
}

struct AppRow: View {
    let app: AppInfo
    let isSelectionMode: Bool
    let isSelected: Bool
    let operation: AppsFeature.ActiveOperation?
    let bulkPhase: AppsFeature.BulkUninstallState.Item.Phase?
    let onDetails: () -> Void
    let onForceStop: () -> Void
    let onClearData: () -> Void
    let onUninstall: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            detailsButton
            if let operation {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(operation.message)
            } else if bulkPhase == .running {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Uninstalling \(app.packageName)")
            } else if case .failed(let message) = bulkPhase {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Could not uninstall \(app.packageName). \(message)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityAction(named: "Force Stop") { onForceStop() }
        .accessibilityAction(named: "Clear Data") { onClearData() }
        .accessibilityAction(named: "Uninstall") { onUninstall() }
    }

    private var detailsButton: some View {
        Button(action: onDetails) {
            HStack(alignment: .center, spacing: 12) {
                if isSelectionMode {
                    Image(systemName: app.isSystemApp ? "lock.circle" : isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(app.isSystemApp ? .secondary : isSelected ? Color.accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                AppGlyph(isSystemApp: app.isSystemApp)

                VStack(alignment: .leading, spacing: 5) {
                    Text(app.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    Text(app.packageName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)

                    if app.isSystemApp {
                        AppTypeBadge(isSystemApp: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .iadbSelectionHighlight(isSelected: isSelectionMode && isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(app.displayName), \(app.packageName), \(app.isSystemApp ? String(localized: "system") : String(localized: "user")) app"
        )
        .accessibilityValue(
            isSelectionMode
                ? app.isSystemApp
                    ? String(localized: "Unavailable for bulk uninstall")
                    : isSelected ? String(localized: "Selected") : String(localized: "Not selected")
                : ""
        )
        .accessibilityHint(
            isSelectionMode ? String(localized: "Changes selection") : String(localized: "Shows app details")
        )
    }

}

private struct AppGlyph: View {
    let isSystemApp: Bool

    var body: some View {
        Image(systemName: isSystemApp ? "gearshape.2.fill" : "app.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 42, height: 42)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct AppTypeBadge: View {
    let isSystemApp: Bool

    var body: some View {
        Label(
            isSystemApp ? String(localized: "System") : String(localized: "User"),
            systemImage: isSystemApp ? "gearshape.fill" : "person.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
            isSystemApp ? String(localized: "System app") : String(localized: "User app")
        )
    }
}

private enum AppActionConfirmation: Equatable {
    case forceStop
    case clearData(DestructiveActionConfirmation?)
    case uninstall(DestructiveActionConfirmation?)

    var title: String {
        switch self {
        case .forceStop: String(localized: "Force Stop App?")
        case .clearData: String(localized: "Clear App Data?")
        case .uninstall: String(localized: "Uninstall App?")
        }
    }

    func message(deviceName: String) -> String {
        switch self {
        case .forceStop:
            String(localized: "Unsaved work in the app may be lost.")
        case .clearData:
            String(localized: "This erases the app's data and cache on \(deviceName).")
        case .uninstall:
            String(localized: "This removes the selected package from \(deviceName).")
        }
    }
}

private struct AppInspectorActions: View {
    let store: StoreOf<AppsFeature>
    let app: AppInfo
    @Binding var confirmation: AppActionConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.headline)

            Button {
                store.send(.launchApp(app))
            } label: {
                Label("Launch", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            Button {
                confirmation = .forceStop
            } label: {
                Label("Force Stop", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmation = .clearData(
                    store.remoteTarget.confirmation(for: app.packageName)
                )
            } label: {
                Label("Clear Data", systemImage: "eraser")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Divider()
            Text("Danger Zone")
                .font(.headline)
            Button(role: .destructive) {
                confirmation = .uninstall(
                    store.remoteTarget.confirmation(for: app.packageName)
                )
            } label: {
                Label("Uninstall from \(store.remoteTarget.deviceName)", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        .disabled(store.operationsByPackage[app.packageName] != nil)
        .appDetailCard()
    }
}

struct AppDetailSheet: View {
    let store: StoreOf<AppsFeature>
    let app: AppInfo?
    let detail: AppDetail?
    let rawDetail: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rawOutputExpanded = false
    @State private var confirmation: AppActionConfirmation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHero

                    DetailInspector(
                        state: detail == nil
                            ? .empty(
                                title: "Details Unavailable",
                                message: "The device did not return structured app information.",
                                symbol: "info.circle"
                            )
                            : .content
                    ) {
                        if let detail {
                            VStack(alignment: .leading, spacing: 18) {
                                DetailSection(
                                    title: String(localized: "Version & Compatibility"),
                                    systemImage: "number.circle",
                                    rows: [
                                        (String(localized: "Version"), detail.versionName ?? String(localized: "Not reported")),
                                        (String(localized: "Version code"), detail.versionCode ?? String(localized: "Not reported")),
                                        (String(localized: "Target SDK"), detail.targetSdk ?? String(localized: "Not reported"))
                                    ]
                                )

                                DetailSection(
                                    title: String(localized: "Installation"),
                                    systemImage: "clock.arrow.circlepath",
                                    rows: [
                                        (String(localized: "First installed"), detail.firstInstallTime ?? String(localized: "Not reported")),
                                        (String(localized: "Last updated"), detail.lastUpdateTime ?? String(localized: "Not reported")),
                                        (String(localized: "Installer"), detail.installerPackage ?? String(localized: "Not reported"))
                                    ]
                                )

                                DetailSection(
                                    title: String(localized: "Paths"),
                                    systemImage: "folder",
                                    rows: [
                                        (String(localized: "Source"), detail.sourcePath ?? String(localized: "Not reported")),
                                        (String(localized: "Data"), detail.dataPath ?? String(localized: "Not reported")),
                                    ]
                                )

                                if !detail.permissions.isEmpty {
                                    DetailSection(
                                        title: String(localized: "Permissions"),
                                        systemImage: "checkmark.shield",
                                        rows: detail.permissions.map { (String(localized: "Permission"), $0) }
                                    )
                                }

                                if !detail.flags.isEmpty {
                                    flagsSection(detail.flags)
                                }
                            }
                        }
                    }

                    if let app {
                        AppInspectorActions(
                            store: store,
                            app: app,
                            confirmation: $confirmation
                        )
                    }

                    rawOutputSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("App Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = rawDetail
                        announceAccessibility("Raw app details copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(rawDetail.isEmpty)
                    .accessibilityLabel("Copy raw app details")
                    .accessibilityHint("Copies the complete package manager output")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            confirmation?.title ?? String(localized: "Confirm App Action"),
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            confirmationButtons
        } message: {
            Text(confirmation?.message(deviceName: store.remoteTarget.deviceName) ?? "")
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        if let confirmation, let app {
            switch confirmation {
            case .forceStop:
                Button("Force Stop", role: .destructive) {
                    store.send(.forceStop(app))
                    self.confirmation = nil
                }
            case .clearData(let targetConfirmation):
                Button("Clear Data", role: .destructive) {
                    store.send(.clearData(app, confirmation: targetConfirmation))
                    self.confirmation = nil
                }
            case .uninstall(let targetConfirmation):
                Button("Uninstall", role: .destructive) {
                    store.send(.uninstall(app, keepData: false, confirmation: targetConfirmation))
                    self.confirmation = nil
                }
                Button("Uninstall and Keep Data", role: .destructive) {
                    store.send(.uninstall(app, keepData: true, confirmation: targetConfirmation))
                    self.confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { self.confirmation = nil }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )
    }

    private var detailHero: some View {
        VStack(spacing: 12) {
            AppGlyph(isSystemApp: app?.isSystemApp ?? false)
                .scaleEffect(1.45)
                .frame(width: 64, height: 64)

            VStack(spacing: 5) {
                Text(app?.displayName ?? detail?.packageName ?? String(localized: "Unknown App"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(detail?.packageName ?? app?.packageName ?? String(localized: "Package unavailable"))
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if let app {
                AppTypeBadge(isSystemApp: app.isSystemApp)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func flagsSection(_ flags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Package Flags", systemImage: "flag")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(flags, id: \.self) { flag in
                    Text(flag)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .appDetailCard()
    }

    private var rawOutputSection: some View {
        DisclosureGroup(isExpanded: $rawOutputExpanded) {
            if rawDetail.isEmpty {
                Text("No raw output was returned.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } else if dynamicTypeSize.isAccessibilitySize {
                Text(rawDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 10)
                    .accessibilityLabel("Raw package manager output")
                    .accessibilityValue(rawDetail)
            } else {
                ScrollView(.horizontal) {
                    Text(rawDetail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 10)
                }
                .accessibilityLabel("Raw package manager output")
            }
        } label: {
            Label("Raw Output", systemImage: "terminal")
                .font(.headline)
        }
        .appDetailCard()
    }
}

struct AppInspectorView: View {
    let store: StoreOf<AppsFeature>
    let app: AppInfo
    @State private var confirmation: AppActionConfirmation?
    @State private var rawOutputExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    TechnicalRow(label: "App", value: app.displayName)
                    Divider()
                    TechnicalRow(
                        label: "Package",
                        value: app.packageName,
                        monospacedValue: true,
                        allowsCopy: true
                    )
                    Divider()
                    TechnicalRow(
                        label: "Type",
                        value: app.isSystemApp ? String(localized: "System") : String(localized: "User")
                    )
                }

                detailContent

                if let detail = matchingDetail, !detail.permissions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Permissions")
                            .font(.headline)
                            .padding(.bottom, 8)
                        ForEach(Array(detail.permissions.enumerated()), id: \.offset) { index, permission in
                            TechnicalRow(
                                label: "Permission \(index + 1)",
                                value: permission,
                                monospacedValue: true,
                                allowsCopy: true
                            )
                            if index < detail.permissions.count - 1 { Divider() }
                        }
                    }
                    .appDetailCard()
                }

                AppInspectorActions(
                    store: store,
                    app: app,
                    confirmation: $confirmation
                )

                DisclosureGroup("Raw Package Dump", isExpanded: $rawOutputExpanded) {
                    if matchingRawDetail.isEmpty {
                        Text("No package dump has been loaded.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(matchingRawDetail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .appDetailCard()
            }
            .padding()
        }
        .navigationTitle("App Inspector")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = matchingRawDetail
                    announceAccessibility("Package dump copied")
                } label: {
                    Label("Copy Package Dump", systemImage: "doc.on.doc")
                }
                .disabled(matchingRawDetail.isEmpty)
            }
        }
        .confirmationDialog(
            confirmation?.title ?? String(localized: "Confirm App Action"),
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            confirmationButtons
        } message: {
            Text(confirmation?.message(deviceName: store.remoteTarget.deviceName) ?? "")
        }
        .accessibilityIdentifier("apps.inspector")
    }

    @ViewBuilder
    private var detailContent: some View {
        if store.isLoadingDetail, store.activeAppDetailPackageName == app.packageName {
            DetailInspector(state: .loading(title: "Loading package details…")) {
                EmptyView()
            }
        } else if let detail = matchingDetail {
            DetailInspector(state: .content) {
                VStack(spacing: 0) {
                    TechnicalRow(label: "Version", value: detail.versionName ?? String(localized: "Not reported"))
                    Divider()
                    TechnicalRow(label: "Version code", value: detail.versionCode ?? String(localized: "Not reported"))
                    Divider()
                    TechnicalRow(label: "Target SDK", value: detail.targetSdk ?? String(localized: "Not reported"))
                    Divider()
                    TechnicalRow(
                        label: "Installer",
                        value: detail.installerPackage ?? String(localized: "Not reported"),
                        monospacedValue: true,
                        allowsCopy: detail.installerPackage != nil
                    )
                    Divider()
                    TechnicalRow(
                        label: "Source path",
                        value: detail.sourcePath ?? String(localized: "Not reported"),
                        monospacedValue: true,
                        allowsCopy: detail.sourcePath != nil
                    )
                    Divider()
                    TechnicalRow(
                        label: "Data path",
                        value: detail.dataPath ?? String(localized: "Not reported"),
                        monospacedValue: true,
                        allowsCopy: detail.dataPath != nil
                    )
                    Divider()
                    TechnicalRow(
                        label: "Permissions",
                        value: detail.permissions.isEmpty
                            ? String(localized: "Not reported")
                            : String(localized: "\(detail.permissions.count) reported")
                    )
                }
            }
        } else {
            DetailInspector(state: .empty(
                title: "Details unavailable",
                message: "Select the app again while connected to load its package metadata.",
                symbol: "info.circle"
            )) {
                EmptyView()
            }
        }
    }

    private var matchingDetail: AppDetail? {
        store.appDetail?.packageName == app.packageName ? store.appDetail : nil
    }

    private var matchingRawDetail: String {
        matchingDetail == nil ? "" : store.appDetailText
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        if let confirmation {
            switch confirmation {
            case .forceStop:
                Button("Force Stop", role: .destructive) {
                    store.send(.forceStop(app))
                    self.confirmation = nil
                }
            case .clearData(let targetConfirmation):
                Button("Clear Data", role: .destructive) {
                    store.send(.clearData(app, confirmation: targetConfirmation))
                    self.confirmation = nil
                }
            case .uninstall(let targetConfirmation):
                Button("Uninstall", role: .destructive) {
                    store.send(.uninstall(app, keepData: false, confirmation: targetConfirmation))
                    self.confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { self.confirmation = nil }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }
}

struct DetailSection: View {
    let title: String
    let systemImage: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    DetailRow(label: row.0, value: row.1)

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .appDetailCard()
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        TechnicalRow(
            localizedLabel: label,
            value: value,
            monospacedValue: label == "Package" || label == "Installer",
            allowsCopy: true
        )
    }
}

private extension View {
    func appDetailCard() -> some View {
        self
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
            )
    }
}
