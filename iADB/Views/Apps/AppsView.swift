import SwiftUI
import UniformTypeIdentifiers
import ComposableArchitecture

struct AppsView: View {
    @Bindable var store: StoreOf<AppsFeature>
    @State private var showingImportPicker = false
    @State private var showingUninstallConfirm = false
    @State private var appToUninstall: AppInfo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Install / Filter bar
                HStack {
                    Toggle("System Apps", isOn: Binding(
                        get: { store.showSystemApps },
                        set: { _ in store.send(.toggleSystemApps) }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)

                    Spacer()

                    Button {
                        showingImportPicker = true
                    } label: {
                        Label("Install APK", systemImage: "plus.app")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Status Messages
                if let status = store.statusMessage {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(status)
                            .font(.caption)
                        Spacer()
                        Button {
                            store.send(.dismissStatus)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                }

                if store.isInstalling {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(store.installProgress)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)
                }

                if let error = store.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }

                // App List
                if store.isLoading {
                    Spacer()
                    ProgressView("Loading packages...")
                    Spacer()
                } else {
                    List(store.filteredApps) { app in
                        AppRow(app: app)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    store.send(.launchApp(app))
                                } label: {
                                    Label("Launch", systemImage: "play.circle")
                                }
                                Button {
                                    store.send(.forceStop(app))
                                } label: {
                                    Label("Force Stop", systemImage: "stop.circle")
                                }
                                Button {
                                    store.send(.clearData(app))
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
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        store.send(.installAPK(data: data, fileName: url.lastPathComponent))
                    }
                }
            }
            .sheet(isPresented: $store.showingAppDetail) {
                AppDetailSheet(app: store.selectedApp, detail: store.appDetailText)
            }
        }
    }
}

struct AppRow: View {
    let app: AppInfo

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
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct AppDetailSheet: View {
    let app: AppInfo?
    let detail: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(app?.packageName ?? "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        UIPasteboard.general.string = detail
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}
