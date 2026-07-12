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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var controlsDisabled: Bool {
        store.isInstalling || store.activeOperation != nil ||
            store.isLoading || store.isLoadingDetail
    }

    private var packageSummary: String {
        let count = store.apps.count
        return count == 1 ? "1 package on device" : "\(count) packages on device"
    }

    private var resultSummary: String {
        let count = store.filteredApps.count
        return count == 1 ? "1 result" : "\(count) results"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                statusArea
                content
            }
            .iadbContentWidth()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $store.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "App name or package"
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.loadApps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload apps")
                    .accessibilityHint("Fetches the installed package list again")
                    .disabled(controlsDisabled)
                }
            }
            .confirmationDialog("Uninstall App?", isPresented: $showingUninstallConfirm) {
                Button("Uninstall", role: .destructive) {
                    if let app = appToUninstall {
                        store.send(.uninstall(app, keepData: false))
                    }
                }
                Button("Uninstall and Keep Data", role: .destructive) {
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
                Text("This erases all data and cache for \(appToClearData?.packageName ?? ""). The app will behave as if freshly installed.")
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
                    store.send(.installAPKFile(url: url, fileName: url.lastPathComponent))
                case .failure(let error):
                    store.send(.importFailed("Could not import the APK: \(error.localizedDescription)"))
                }
            }
            .sheet(isPresented: $store.showingAppDetail) {
                AppDetailSheet(
                    app: store.selectedApp,
                    detail: store.appDetail,
                    rawDetail: store.appDetailText
                )
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    librarySummary
                    installButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        librarySummary
                        Spacer(minLength: 12)
                        installButton
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        librarySummary
                        installButton
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        packageTypeLabel
                        sortMenu
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center) {
                            packageTypeLabel
                            Spacer()
                            sortMenu
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            packageTypeLabel
                            sortMenu
                        }
                    }
                }

                Picker("Package type", selection: Binding(
                    get: { store.filter },
                    set: { store.send(.setFilter($0)) }
                )) {
                    ForEach(AppsFeature.AppFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Package type filter")
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var packageTypeLabel: some View {
        Label("Package type", systemImage: "line.3.horizontal.decrease.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AppsFeature.AppSort.allCases, id: \.self) { sort in
                Button {
                    store.send(.setSort(sort))
                } label: {
                    if store.sort == sort {
                        Label(sort.rawValue, systemImage: "checkmark")
                    } else {
                        Text(sort.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort: \(store.sort.rawValue)", systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel("Sort apps by \(store.sort.rawValue)")
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
        .disabled(controlsDisabled)
        .accessibilityHint("Choose an Android package file to install")
    }

    @ViewBuilder
    private var statusArea: some View {
        if store.statusMessage != nil || store.isInstalling || store.activeOperation != nil ||
            store.isLoadingDetail || store.errorMessage != nil {
            VStack(spacing: 8) {
                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: store.apps.isEmpty ? "Retry" : nil,
                        onDismiss: { store.send(.dismissError) },
                        onAction: store.apps.isEmpty ? { store.send(.loadApps) } : nil
                    )
                }

                if store.isInstalling {
                    StatusBannerView(
                        style: .progress,
                        message: store.installProgress,
                        showsProgress: true,
                        actionTitle: "Cancel",
                        onAction: { store.send(.cancelInstall) }
                    )
                }

                if let operation = store.activeOperation {
                    StatusBannerView(
                        style: .progress,
                        message: operation.message,
                        showsProgress: true,
                        actionTitle: "Cancel",
                        onAction: { store.send(.cancelOperation) }
                    )
                }

                if store.isLoadingDetail {
                    StatusBannerView(
                        style: .progress,
                        message: "Loading app details…",
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
        if store.isLoading {
            AppsLoadingView()
        } else if store.filteredApps.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(store.filteredApps) { app in
                        AppRow(
                            app: app,
                            onLaunch: { store.send(.launchApp(app)) },
                            onDetails: { store.send(.getAppDetail(app)) },
                            onForceStop: {
                                appToForceStop = app
                                showingForceStopConfirm = true
                            },
                            onClearData: {
                                appToClearData = app
                                showingClearDataConfirm = true
                            },
                            onUninstall: {
                                appToUninstall = app
                                showingUninstallConfirm = true
                            }
                        )
                        .disabled(controlsDisabled)
                        .contextMenu {
                            appActions(for: app)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                appToUninstall = app
                                showingUninstallConfirm = true
                            } label: {
                                Label("Uninstall", systemImage: "trash")
                            }
                            .accessibilityLabel("Uninstall \(app.displayName)")
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
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                store.searchText.isEmpty ? "No Apps to Show" : "No Matching Apps",
                systemImage: store.searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass"
            )
        } description: {
            if !store.searchText.isEmpty {
                Text("No app names or package identifiers match “\(store.searchText)”.")
            } else if store.apps.isEmpty {
                Text("Reload installed apps, or install an APK to get started.")
            } else {
                Text("No packages match the \(store.filter.rawValue.lowercased()) filter.")
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
            appToClearData = app
            showingClearDataConfirm = true
        } label: {
            Label("Clear Data", systemImage: "eraser")
        }

        Divider()

        Button(role: .destructive) {
            appToUninstall = app
            showingUninstallConfirm = true
        } label: {
            Label("Uninstall", systemImage: "trash")
        }
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

struct AppRow: View {
    let app: AppInfo
    let onLaunch: () -> Void
    let onDetails: () -> Void
    let onForceStop: () -> Void
    let onClearData: () -> Void
    let onUninstall: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    detailsButton

                    HStack(spacing: 10) {
                        launchButton(showsTitle: true)
                        Spacer(minLength: 8)
                        overflowMenu
                    }
                    .padding(.leading, 54)
                }
            } else {
                HStack(spacing: 10) {
                    detailsButton
                    launchButton(showsTitle: false)
                    overflowMenu
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var detailsButton: some View {
        Button(action: onDetails) {
            HStack(alignment: .center, spacing: 12) {
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

                    AppTypeBadge(isSystemApp: app.isSystemApp)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(app.displayName), \(app.packageName), \(app.isSystemApp ? "system" : "user") app"
        )
        .accessibilityHint("Shows app details")
    }

    @ViewBuilder
    private func launchButton(showsTitle: Bool) -> some View {
        Button(action: onLaunch) {
            if showsTitle {
                Label("Launch", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
            } else {
                Image(systemName: "play.fill")
                    .font(.body.weight(.semibold))
            }
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Launch \(app.displayName)")
        .accessibilityHint("Opens the app on the connected device")
    }

    private var overflowMenu: some View {
        Menu {
            Button(action: onDetails) {
                Label("View Details", systemImage: "info.circle")
            }

            Button(action: onForceStop) {
                Label("Force Stop", systemImage: "stop.circle")
            }

            Button(role: .destructive, action: onClearData) {
                Label("Clear Data", systemImage: "eraser")
            }

            Divider()

            Button(role: .destructive, action: onUninstall) {
                Label("Uninstall", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(app.displayName)")
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
            isSystemApp ? "System" : "User",
            systemImage: isSystemApp ? "gearshape.fill" : "person.fill"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .accessibilityLabel(isSystemApp ? "System app" : "User app")
    }
}

struct AppDetailSheet: View {
    let app: AppInfo?
    let detail: AppDetail?
    let rawDetail: String

    @Environment(\.dismiss) private var dismiss
    @State private var rawOutputExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHero

                    if let detail {
                        DetailSection(
                            title: "Version & Compatibility",
                            systemImage: "number.circle",
                            rows: [
                                ("Version", detail.versionName ?? "Not reported"),
                                ("Version code", detail.versionCode ?? "Not reported"),
                                ("Target SDK", detail.targetSdk ?? "Not reported")
                            ]
                        )

                        DetailSection(
                            title: "Installation",
                            systemImage: "clock.arrow.circlepath",
                            rows: [
                                ("First installed", detail.firstInstallTime ?? "Not reported"),
                                ("Last updated", detail.lastUpdateTime ?? "Not reported"),
                                ("Installer", detail.installerPackage ?? "Not reported")
                            ]
                        )

                        if !detail.flags.isEmpty {
                            flagsSection(detail.flags)
                        }
                    } else {
                        ContentUnavailableView(
                            "Details Unavailable",
                            systemImage: "info.circle",
                            description: Text("The device did not return structured app information.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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
    }

    private var detailHero: some View {
        VStack(spacing: 12) {
            AppGlyph(isSystemApp: app?.isSystemApp ?? false)
                .scaleEffect(1.45)
                .frame(width: 64, height: 64)

            VStack(spacing: 5) {
                Text(app?.displayName ?? detail?.packageName ?? "Unknown App")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(detail?.packageName ?? app?.packageName ?? "Package unavailable")
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
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
