import SwiftUI
import UniformTypeIdentifiers
import ComposableArchitecture

struct AppsView: View {
    @Bindable var store: StoreOf<AppsFeature>
    @State private var showingImportPicker = false
    @State private var showingUninstallConfirm = false
    @State private var appToUninstall: AppInfo?
    @State private var showingClearDataConfirm = false
    @State private var appToClearData: AppInfo?
    @State private var showingForceStopConfirm = false
    @State private var appToForceStop: AppInfo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Picker("Filter", selection: Binding(
                        get: { store.filter },
                        set: { store.send(.setFilter($0)) }
                    )) {
                        ForEach(AppsFeature.AppFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Menu {
                            ForEach(AppsFeature.AppSort.allCases, id: \.self) { sort in
                                Button(sort.rawValue) {
                                    store.send(.setSort(sort))
                                }
                            }
                        } label: {
                            Label(store.sort.rawValue, systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                        }

                        Spacer()

                        Button {
                            showingImportPicker = true
                        } label: {
                            Label("Install APK", systemImage: "plus.app")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            store.isInstalling || store.activeOperation != nil ||
                            store.isLoading || store.isLoadingDetail
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if let status = store.statusMessage {
                    StatusBannerView(style: .success, message: status, onDismiss: {
                        store.send(.dismissStatus)
                    })
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if store.isInstalling {
                    StatusBannerView(
                        style: .progress,
                        message: store.installProgress,
                        showsProgress: true,
                        actionTitle: "Cancel",
                        onAction: { store.send(.cancelInstall) }
                    )
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if let operation = store.activeOperation {
                    StatusBannerView(
                        style: .progress,
                        message: operation.message,
                        showsProgress: true,
                        actionTitle: "Cancel",
                        onAction: { store.send(.cancelOperation) }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if store.isLoadingDetail {
                    StatusBannerView(
                        style: .progress,
                        message: "Loading app details...",
                        showsProgress: true
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: store.apps.isEmpty ? "Retry" : nil,
                        onDismiss: { store.send(.dismissError) },
                        onAction: store.apps.isEmpty ? { store.send(.loadApps) } : nil
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                // App List
                if store.isLoading {
                    Spacer()
                    ProgressView("Loading packages...")
                    Spacer()
                } else if store.filteredApps.isEmpty {
                    ContentUnavailableView {
                        Label(
                            store.searchText.isEmpty ? "No Apps Found" : "No Matching Apps",
                            systemImage: store.searchText.isEmpty ? "app.dashed" : "magnifyingglass"
                        )
                    } description: {
                        Text(store.searchText.isEmpty
                             ? "No packages match the selected filter."
                             : "Try a different package name or clear the search.")
                    } actions: {
                        if store.searchText.isEmpty {
                            Button("Reload") { store.send(.loadApps) }
                        } else {
                            Button("Clear Search") {
                                store.send(.binding(.set(\.searchText, "")))
                            }
                        }
                    }
                } else {
                    List(store.filteredApps) { app in
                        AppRow(
                            app: app,
                            onLaunch: { store.send(.launchApp(app)) },
                            onDetails: { store.send(.getAppDetail(app)) }
                        )
                            .disabled(
                                store.activeOperation != nil || store.isInstalling ||
                                store.isLoadingDetail
                            )
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    store.send(.launchApp(app))
                                } label: {
                                    Label("Launch", systemImage: "play.circle")
                                }
                                Button {
                                    appToForceStop = app
                                    showingForceStopConfirm = true
                                } label: {
                                    Label("Force Stop", systemImage: "stop.circle")
                                }
                                Button(role: .destructive) {
                                    appToClearData = app
                                    showingClearDataConfirm = true
                                } label: {
                                    Label("Clear Data", systemImage: "eraser")
                                }
                                Button {
                                    store.send(.getAppDetail(app))
                                } label: {
                                    Label("Details", systemImage: "info.circle")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    appToUninstall = app
                                    showingUninstallConfirm = true
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    appToUninstall = app
                                    showingUninstallConfirm = true
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                            }
                    }
                    .listStyle(.plain)
                    .searchable(text: $store.searchText, prompt: "Search packages")
                }
            }
            .navigationTitle("Apps (\(store.filteredApps.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.loadApps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload apps")
                    .disabled(
                        store.isLoading || store.isInstalling ||
                        store.activeOperation != nil || store.isLoadingDetail
                    )
                }
            }
            .confirmationDialog("Uninstall App?", isPresented: $showingUninstallConfirm) {
                Button("Uninstall", role: .destructive) {
                    if let app = appToUninstall {
                        store.send(.uninstall(app, keepData: false))
                    }
                }
                Button("Uninstall (Keep Data)", role: .destructive) {
                    if let app = appToUninstall {
                        store.send(.uninstall(app, keepData: true))
                    }
                }
            } message: {
                Text("Uninstall \(appToUninstall?.packageName ?? "")?")
            }
            .confirmationDialog("Clear App Data?", isPresented: $showingClearDataConfirm) {
                Button("Clear Data", role: .destructive) {
                    if let app = appToClearData {
                        store.send(.clearData(app))
                    }
                }
            } message: {
                Text("This will erase all data and cache for \(appToClearData?.packageName ?? ""). The app will behave as if freshly installed.")
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
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    store.send(.installAPKFile(url: url, fileName: url.lastPathComponent))
                case .failure(let error):
                    store.send(.importFailed("Could not import the APK: \(error.localizedDescription)"))
                }
            }
            .sheet(isPresented: $store.showingAppDetail) {
                AppDetailSheet(app: store.selectedApp, detail: store.appDetail, rawDetail: store.appDetailText)
            }
        }
    }
}

struct AppRow: View {
    let app: AppInfo
    let onLaunch: () -> Void
    let onDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(app.packageName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(app.isSystemApp ? "SYSTEM" : "USER")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(app.isSystemApp ? .orange : .blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((app.isSystemApp ? Color.orange : Color.blue).opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            Button(action: onLaunch) {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Launch \(app.displayName)")

            Button(action: onDetails) {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Show details for \(app.displayName)")
        }
        .padding(.vertical, 2)
    }
}

struct AppDetailSheet: View {
    let app: AppInfo?
    let detail: AppDetail?
    let rawDetail: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let detail {
                        DetailSection(title: "Overview", rows: [
                            ("Package", detail.packageName),
                            ("Version", detail.versionName ?? "-"),
                            ("Version Code", detail.versionCode ?? "-"),
                            ("Target SDK", detail.targetSdk ?? "-"),
                            ("Installed", detail.firstInstallTime ?? "-"),
                            ("Updated", detail.lastUpdateTime ?? "-"),
                            ("Installer", detail.installerPackage ?? "-"),
                        ])

                        if !detail.flags.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Flags")
                                    .font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 8) {
                                    ForEach(detail.flags, id: \.self) { flag in
                                        Text(flag)
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(Color(.systemGray6))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Raw Output")
                            .font(.headline)
                        Text(rawDetail)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle(app?.packageName ?? "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        UIPasteboard.general.string = rawDetail
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

struct DetailSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(row.1)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
        }
    }
}
