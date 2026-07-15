import SwiftUI
import ComposableArchitecture
import UIKit

/// Five task-oriented roots keep navigation predictable on iPhone and iPad.
struct AdaptiveAppShell: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("iadb.shell.selectedRoot") private var restoredRoot = AppShellFeature.Root.device.rawValue
    @SceneStorage("iadb.shell.consoleSection") private var restoredConsoleSection = AppShellFeature.ConsoleSection.commandRunner.rawValue
    @State private var showingConnections = false

    var body: some View {
        Group {
            if !store.hasEnteredWorkspace {
                connectionEntry
            } else if usesSplitLayout {
                regularShell
            } else {
                compactShell
            }
        }
        .popover(
            isPresented: Binding(
                get: { store.appShell.isDeviceSwitcherPresented },
                set: { store.send(.appShell(.setDeviceSwitcherPresented($0))) }
            )
        ) {
            DeviceSwitcher(
                session: store.session,
                nearbyDevices: store.connection.discoveredDevices,
                savedDevices: store.connection.pairedDevices,
                onSelect: { device in
                    store.send(.appShell(.setDeviceSwitcherPresented(false)))
                    store.send(.connection(.connectToDevice(device)))
                },
                onManageConnections: {
                    store.send(.appShell(.setDeviceSwitcherPresented(false)))
                    showingConnections = true
                }
            )
        }
        .fullScreenCover(isPresented: $showingConnections) {
            ConnectionsFlowView(
                store: store.scope(state: \.connection, action: \.connection),
                allowsDismissWhenConnected: true,
                startsDiscoveryOnAppear: false
            )
        }
        .popover(
            isPresented: Binding(
                get: { store.operations.isPresented },
                set: { store.send(.operations(.setPresented($0))) }
            )
        ) {
            ActivityCenterView(store: store.scope(state: \.operations, action: \.operations))
                .frame(idealWidth: 400, idealHeight: 560)
                .presentationCompactAdaptation(.sheet)
        }
        .overlay(alignment: .top) {
            if let toast = store.feedback.toast {
                FeedbackToast(feedback: toast)
                    .padding(.top, 8)
                    .transition(dynamicTypeSize.isAccessibilitySize || reduceMotion ? .identity : .opacity)
                    .zIndex(2)
            }
        }
        .iadbDismissKeyboardOnOutsideTap()
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            guard !arguments.contains(where: {
                $0.hasPrefix("--iadb-") || $0.hasPrefix("--ui-testing") || $0 == "--app-store-screenshots"
            }) else { return }
            guard let root = AppShellFeature.Root(rawValue: restoredRoot),
                  let section = AppShellFeature.ConsoleSection(rawValue: restoredConsoleSection) else {
                return
            }
            store.send(.appShell(.restore(selectedRoot: root, consoleSection: section)))
        }
        .onChange(of: store.appShell.selectedRoot) { _, root in
            restoredRoot = root.rawValue
        }
        .onChange(of: store.appShell.consoleSection) { _, section in
            restoredConsoleSection = section.rawValue
        }
    }

    @ViewBuilder
    private var connectionEntry: some View {
        if store.isConnectionSetupPresented {
            ConnectionsFlowView(
                store: store.scope(state: \.connection, action: \.connection),
                allowsDismissWhenConnected: false
            )
            .accessibilityIdentifier("onboarding.connections")
        } else {
            ConnectionOnboardingView {
                store.send(.showConnectionSetup)
            }
        }
    }

    private var usesSplitLayout: Bool {
        Self.shouldUseSplitLayout(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isHorizontalRegular: horizontalSizeClass == .regular,
            isAccessibilityText: dynamicTypeSize.isAccessibilitySize
        )
    }

    static func shouldUseSplitLayout(
        isPad: Bool,
        isHorizontalRegular _: Bool,
        isAccessibilityText: Bool
    ) -> Bool {
        !isAccessibilityText && isPad
    }

    private var compactShell: some View {
        TabView(selection: visibleTabBinding) {
            compactWorkspace(showsDeviceContext: false) {
                DeviceHubView(
                    connectionStore: store.scope(state: \.connection, action: \.connection),
                    deviceStore: store.scope(state: \.device, action: \.device),
                    screenshotStore: store.scope(state: \.screenshot, action: \.screenshot),
                    session: store.session,
                    operations: store.operations
                )
            }
                .tabItem {
                    Label("Device", systemImage: "smartphone")
                }
                .tag(AppFeature.Tab.device)

            compactWorkspace {
                FileManagerView(
                    store: store.scope(state: \.fileManager, action: \.fileManager),
                    focusRequestID: store.appShell.focusRequestID
                )
            }
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(AppFeature.Tab.files)

            compactWorkspace {
                AppsView(
                    store: store.scope(state: \.apps, action: \.apps),
                    focusRequestID: store.appShell.focusRequestID
                )
            }
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
                .tag(AppFeature.Tab.apps)

            compactWorkspace {
                ConsoleView(
                    shellStore: store.scope(state: \.shell, action: \.shell),
                    logcatStore: store.scope(state: \.logcat, action: \.logcat),
                    appShellStore: store.scope(state: \.appShell, action: \.appShell)
                )
            }
                .tabItem {
                    Label("Console", systemImage: "terminal")
                }
                .tag(AppFeature.Tab.console)

            compactWorkspace {
                ScreenshotView(store: store.scope(state: \.screenshot, action: \.screenshot))
            }
                .tabItem {
                    Label("Screens", systemImage: "rectangle.stack")
                }
                .tag(AppFeature.Tab.screens)
        }
        .background(
            TabBarAccessibilityIdentifierInstaller(
                identifiers: ["root.device", "root.files", "root.apps", "root.console", "root.screens"]
            )
        )
    }

    private var regularShell: some View {
        NavigationSplitView(columnVisibility: splitVisibilityBinding) {
            VStack(spacing: 0) {
                deviceContext(compact: false)
                List(selection: rootBinding) {
                    Section("Workspaces") {
                        sidebarRoot("Device", symbol: "smartphone", root: .device)
                        sidebarRoot("Files", symbol: "folder", root: .files)
                        sidebarRoot("Apps", symbol: "square.grid.2x2", root: .apps)
                        sidebarRoot("Console", symbol: "terminal", root: .console)
                        sidebarRoot("Screens", symbol: "rectangle.stack", root: .screens)
                    }
                    contextualSidebar
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 340)
        } content: {
            VStack(spacing: 0) {
                feedbackAndActivity
                workspaceView(root: store.appShell.selectedRoot)
            }
            .accessibilityIdentifier("shell.content")
        } detail: {
            regularDetail
                .accessibilityIdentifier("shell.detail")
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("shell.split")
    }

    @ViewBuilder
    private func workspaceView(root: AppShellFeature.Root) -> some View {
        switch root {
        case .device:
            DeviceHubView(
                connectionStore: store.scope(state: \.connection, action: \.connection),
                deviceStore: store.scope(state: \.device, action: \.device),
                screenshotStore: store.scope(state: \.screenshot, action: \.screenshot),
                session: store.session,
                operations: store.operations
            )
        case .files:
            FileManagerView(
                store: store.scope(state: \.fileManager, action: \.fileManager),
                focusRequestID: store.appShell.focusRequestID,
                layout: .regular
            )
        case .apps:
            AppsView(
                store: store.scope(state: \.apps, action: \.apps),
                focusRequestID: store.appShell.focusRequestID,
                layout: .regular
            )
        case .console:
            ConsoleView(
                shellStore: store.scope(state: \.shell, action: \.shell),
                logcatStore: store.scope(state: \.logcat, action: \.logcat),
                appShellStore: store.scope(state: \.appShell, action: \.appShell)
            )
        case .screens:
            ScreenshotView(
                store: store.scope(state: \.screenshot, action: \.screenshot),
                layout: .regular
            )
        }
    }

    @ViewBuilder
    private var contextualSidebar: some View {
        switch store.appShell.selectedRoot {
        case .files:
            Section("Favorites") {
                ForEach(store.fileManager.favorites, id: \.self) { path in
                    Button {
                        store.send(.fileManager(.navigateToPath(path)))
                    } label: {
                        Label(path, systemImage: "folder")
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                    }
                }
            }
            Section("Current Directory") {
                ForEach(store.fileManager.entries.filter(\.isNavigableDirectory)) { entry in
                    Button {
                        store.send(.fileManager(.navigateTo(entry)))
                    } label: {
                        Label(entry.displayName, systemImage: "folder")
                            .lineLimit(1)
                    }
                }
            }
            Section("Recent Paths") {
                ForEach(recentFilePaths, id: \.self) { path in
                    Button {
                        store.send(.fileManager(.navigateToPath(path)))
                    } label: {
                        Label(path, systemImage: "clock")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
            }
        case .console:
            Section("Console") {
                Button("Command Runner", systemImage: "terminal") {
                    store.send(.appShell(.selectConsoleSection(.commandRunner)))
                }
                Button("Logcat", systemImage: "text.alignleft") {
                    store.send(.appShell(.selectConsoleSection(.logcat)))
                }
            }
        case .screens:
            Section("Gallery") {
                Button("Group by Day", systemImage: store.screenshot.grouping == .day ? "checkmark" : "calendar") {
                    store.send(.screenshot(.setGrouping(.day)))
                }
                Button("Group by Device", systemImage: store.screenshot.grouping == .device ? "checkmark" : "smartphone") {
                    store.send(.screenshot(.setGrouping(.device)))
                }
            }
            Section("Local Storage") {
                LabeledContent("Captures", value: "\(store.screenshot.screenshots.count)")
                LabeledContent(
                    "Used",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(store.screenshot.storageByteCount),
                        countStyle: .file
                    )
                )
            }
        default:
            EmptyView()
        }
    }

    private var recentFilePaths: [String] {
        var seen = Set<String>()
        return store.fileManager.pathHistory.reversed().filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    private func sidebarRoot(
        _ title: String,
        symbol: String,
        root: AppShellFeature.Root
    ) -> some View {
        Label(title, systemImage: symbol)
            .tag(root)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("root.\(root.rawValue)")
    }

    @ViewBuilder
    private var regularDetail: some View {
        switch store.appShell.selectedRoot {
        case .files:
            if let file = store.fileManager.selectedFile {
                FileInspectorView(
                    store: store.scope(state: \.fileManager, action: \.fileManager),
                    file: file
                )
            } else {
                emptyInspector("Select a file", message: "Choose a file to inspect metadata and preview options.", symbol: "doc")
            }
        case .apps:
            if let app = store.apps.selectedApp {
                AppInspectorView(
                    store: store.scope(state: \.apps, action: \.apps),
                    app: app
                )
            } else {
                emptyInspector("Select an app", message: "Choose an app to inspect metadata and available actions.", symbol: "shippingbox")
            }
        case .screens:
            if let screenshot = store.screenshot.selectedScreenshot {
                ScreenshotInspectorView(
                    store: store.scope(state: \.screenshot, action: \.screenshot),
                    entry: screenshot
                )
            } else {
                emptyInspector("Select a screenshot", message: "Choose a local capture to inspect or share.", symbol: "photo")
            }
        case .device:
            ScrollView {
                VStack(spacing: 0) {
                    TechnicalRow(
                        label: "Device",
                        value: store.session.selectedDevice?.displayName ?? String(localized: "No device selected")
                    )
                    Divider()
                    TechnicalRow(
                        label: "Status",
                        value: deviceConnectionSummary
                    )
                    Divider()
                    TechnicalRow(
                        label: "Endpoint",
                        value: store.session.lastKnownEndpoint?.displayValue ?? "—",
                        monospacedValue: true,
                        allowsCopy: store.session.lastKnownEndpoint != nil
                    )
                    Divider()
                    TechnicalRow(
                        label: "Recent activity",
                        value: store.operations.operations.isEmpty
                            ? String(localized: "No recent operations")
                            : String(localized: "\(store.operations.operations.count) operations")
                    )
                }
                .padding()
            }
            .navigationTitle("Connection Summary")
        case .console:
            if store.appShell.consoleSection == .commandRunner,
               let id = store.shell.selectedHistoryID,
               let entry = store.shell.visibleHistory.first(where: { $0.id == id }) {
                ShellHistoryInspectorView(
                    store: store.scope(state: \.shell, action: \.shell),
                    entry: entry
                )
            } else if store.appShell.consoleSection == .logcat,
                      let id = store.logcat.selectedEntryID,
                      let entry = store.logcat.entries.first(where: { $0.id == id }) {
                LogcatInspectorView(
                    store: store.scope(state: \.logcat, action: \.logcat),
                    entry: entry
                )
            } else {
                if store.appShell.consoleSection == .commandRunner {
                    emptyInspector("Select a command", message: "Choose a command to inspect output and execution metadata.", symbol: "terminal")
                } else {
                    emptyInspector("Select a log entry", message: "Choose a row to inspect its full message and process metadata.", symbol: "text.alignleft")
                }
            }
        }
    }

    private var deviceConnectionSummary: String {
        switch store.session.transport {
        case .noDevice: String(localized: "No device")
        case .paired: String(localized: "Paired")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .disconnected: String(localized: "Disconnected")
        }
    }

    private func emptyInspector(
        _ title: LocalizedStringResource,
        message: LocalizedStringResource,
        symbol: String
    ) -> some View {
        DetailInspector(state: .empty(title: title, message: message, symbol: symbol)) {
            EmptyView()
        }
    }

    private func compactWorkspace<Content: View>(
        showsDeviceContext: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if showsDeviceContext {
                deviceContext(compact: true)
            }
            feedbackAndActivity
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deviceContext(compact: Bool) -> some View {
        DeviceContextBar(
            session: store.session,
            activeOperationCount: store.operations.activeCount,
            compact: compact,
            onOpenSwitcher: { store.send(.appShell(.setDeviceSwitcherPresented(true))) },
            onReconnect: { store.send(.connection(.reconnectLastDevice)) },
            onCancelReconnect: { store.send(.connection(.cancelConnection)) },
            onOpenActivity: { store.send(.operations(.setPresented(true))) }
        )
    }

    @ViewBuilder
    private var feedbackAndActivity: some View {
        let banner = store.feedback.banner(for: selectedWorkspace)
        if banner != nil || (store.appShell.selectedRoot == .device && !store.operations.operations.isEmpty) {
            VStack(spacing: IADBDesign.spacing8) {
                if let banner {
                    StatusBannerPresenter(
                        feedback: banner,
                        onDismiss: {
                            store.send(.feedback(.dismiss(workspace: selectedWorkspace, id: banner.id)))
                        },
                        onRecovery: handleRecovery
                    )
                }
                if store.appShell.selectedRoot == .device && !store.operations.operations.isEmpty {
                    activityButton
                }
            }
            .padding(.horizontal, IADBDesign.spacing12)
            .padding(.vertical, IADBDesign.spacing4)
            .background(Color(uiColor: .secondarySystemBackground))
        }
    }

    private var activityButton: some View {
        Button {
            store.send(.operations(.setPresented(true)))
        } label: {
            Label(activityLabel, systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: IADBDesign.minimumHitTarget)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("activity.open")
    }

    private var activityLabel: String {
        let active = store.operations.activeCount
        return active == 0
            ? String(localized: "Activity")
            : String(localized: "Activity, \(active) active")
    }

    private var selectedWorkspace: WorkspaceRoot {
        switch store.selectedTab.visibleRoot {
        case .device, .connection: .device
        case .files: .files
        case .apps: .apps
        case .shell, .logcat, .console: .console
        case .screenshot, .screens: .screens
        }
    }

    private func handleRecovery(_ recovery: FeedbackRecovery) {
        switch recovery {
        case .reconnect:
            store.send(.connection(.reconnectLastDevice))
        case .retryOperation(let id):
            store.send(.operations(.retryTapped(id)))
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        case .details:
            store.send(.operations(.setPresented(true)))
        }
    }

    private var visibleTabBinding: Binding<AppFeature.Tab> {
        Binding(
            get: { store.selectedTab.visibleRoot },
            set: { store.send(.selectTab($0)) }
        )
    }

    private var rootBinding: Binding<AppShellFeature.Root?> {
        Binding(
            get: { store.appShell.selectedRoot },
            set: { root in
                if let root { store.send(.appShell(.selectRoot(root))) }
            }
        )
    }

    private var splitVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch store.appShell.columnVisibility {
                case .all: .all
                case .contentAndDetail: .doubleColumn
                case .detailOnly: .detailOnly
                }
            },
            set: { visibility in
                let mapped: AppShellFeature.ColumnVisibility
                if visibility == .all || visibility == .automatic {
                    mapped = .all
                } else if visibility == .doubleColumn {
                    mapped = .contentAndDetail
                } else {
                    mapped = .detailOnly
                }
                store.send(.appShell(.setColumnVisibility(mapped)))
            }
        )
    }
}

private struct ConnectionOnboardingView: View {
    let connect: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                    IADBIconTile(
                        symbol: "cable.connector.horizontal",
                        tint: .accentColor
                    )

                    VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                        Text("Connect an Android Device")
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Pair over your local network before opening the iADB workspaces.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: IADBDesign.spacing12) {
                        onboardingRow(
                            "Enable Wireless debugging",
                            detail: String(localized: "Open Developer options on Android."),
                            symbol: "gearshape.2"
                        )
                        onboardingRow(
                            "Keep both devices nearby",
                            detail: String(localized: "They must be on the same local network."),
                            symbol: "wifi"
                        )
                        onboardingRow(
                            "Pair, then connect",
                            detail: String(localized: "Android uses separate pairing and connection ports."),
                            symbol: "link"
                        )
                    }
                }
                .padding(IADBDesign.contentPadding)
                .padding(.top, IADBDesign.sectionSpacing)
                .padding(.bottom, 96)
                .iadbReadableWidth(maxWidth: 620)
            }
            .background(IADBScreenBackground())
            .navigationTitle("iADB")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: connect) {
                    Label("Connect a Device", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: IADBDesign.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 620)
                .padding(.horizontal, IADBDesign.contentPadding)
                .padding(.vertical, IADBDesign.spacing12)
                .background(.bar)
                .accessibilityIdentifier("onboarding.connect")
            }
        }
        .accessibilityIdentifier("onboarding.connection")
    }

    private func onboardingRow(
        _ title: LocalizedStringResource,
        detail: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: IADBDesign.spacing12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: IADBDesign.minimumHitTarget, height: IADBDesign.minimumHitTarget)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: IADBDesign.controlRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: IADBDesign.spacing4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Source-compatible name retained while callers migrate to the adaptive shell.
typealias MainTabView = AdaptiveAppShell

/// SwiftUI does not forward `accessibilityIdentifier` from a `tabItem` label
/// to the system `UITabBarItem`. This metadata-only bridge keeps UI tests
/// independent from localized tab titles without replacing native TabView.
private struct TabBarAccessibilityIdentifierInstaller: UIViewControllerRepresentable {
    let identifiers: [String]

    func makeUIViewController(context: Context) -> InstallerViewController {
        InstallerViewController(identifiers: identifiers)
    }

    func updateUIViewController(_ viewController: InstallerViewController, context: Context) {
        viewController.identifiers = identifiers
        viewController.installIdentifiers()
    }

    final class InstallerViewController: UIViewController {
        var identifiers: [String]

        init(identifiers: [String]) {
            self.identifiers = identifiers
            super.init(nibName: nil, bundle: nil)
            view.isHidden = true
            view.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIdentifiers()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIdentifiers()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIdentifiers()
        }

        func installIdentifiers() {
            guard let root = view.window?.rootViewController,
                  let tabBarController = findTabBarController(in: root),
                  let items = tabBarController.tabBar.items,
                  items.count == identifiers.count else {
                return
            }
            for (item, identifier) in zip(items, identifiers) {
                item.accessibilityIdentifier = identifier
            }
        }

        private func findTabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            for child in controller.children {
                if let match = findTabBarController(in: child) {
                    return match
                }
            }
            if let presented = controller.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }
    }
}

enum StatusBannerStyle: Equatable {
    case info
    case success
    case warning
    case error
    case progress

    var iconName: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .progress: return "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .progress: return .accentColor
        }
    }

    var background: Color {
        tint.opacity(0.12)
    }
}

struct StatusBannerView: View {
    let style: StatusBannerStyle
    let message: String
    var showsProgress = false
    var actionTitle: String? = nil
    var onDismiss: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsProgress {
                    ProgressView()
                        .tint(style.tint)
                } else {
                    Image(systemName: style.iconName)
                        .foregroundColor(style.tint)
                }

                Text(message)
                    .font(.caption)
                    .foregroundColor(.primary)

                Spacer(minLength: 0)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.banner")
        .onAppear {
            announceErrorIfNeeded(message)
        }
        .onChange(of: message) { _, newMessage in
            announceErrorIfNeeded(newMessage)
        }
    }

    private func announceErrorIfNeeded(_ message: String) {
        guard style == .error else { return }
        let announcement = actionTitle.map { "\(message). Recovery action: \($0)." } ?? message
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}
