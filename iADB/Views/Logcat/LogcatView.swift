import SwiftUI
import UIKit
import ComposableArchitecture

struct LogcatView: View {
    @Bindable var store: StoreOf<LogcatFeature>
    let isEmbeddedInNavigationStack: Bool
    let focusRequestID: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingExportSheet = false
    @State private var exportText = ""
    @State private var isShowingFilters = false
    @FocusState private var isSearchFocused: Bool

    init(
        store: StoreOf<LogcatFeature>,
        isEmbeddedInNavigationStack: Bool = false,
        focusRequestID: Int = 0
    ) {
        self.store = store
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.focusRequestID = focusRequestID
    }

    var body: some View {
        Group {
            if isEmbeddedInNavigationStack {
                logcatContent
                    .toolbar { logcatToolbar }
            } else {
                NavigationStack {
                    logcatContent
                        .navigationTitle("Logcat")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { logcatToolbar }
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onChange(of: focusRequestID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            isSearchFocused = true
        }
        .sheet(isPresented: $showingExportSheet, onDismiss: {
            exportText = ""
            store.send(.clearExport)
        }) {
            ShareTextSheet(text: exportText, fileName: "logcat.txt")
        }
        .sheet(isPresented: filterSheetBinding) {
            LogcatFilterView(store: store)
                .iadbAdaptiveSheetHeight()
        }
        .sheet(isPresented: exportReviewBinding) {
            LogcatExportReviewView(store: store)
                .iadbAdaptiveSheetHeight()
        }
        .onChange(of: store.exportText) { _, value in
            guard let value else { return }
            exportText = value
            showingExportSheet = true
        }
    }

    private var logcatContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: String(localized: "Retry"),
                        onDismiss: { store.send(.dismissError) },
                        onAction: { store.send(.startLogcat) }
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                controlsRegion(maxHeight: geometry.size.height * 0.48)

                Divider()

                logContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom) { followStatus }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("workspace.logcat")
    }

    @ViewBuilder
    private func controlsRegion(maxHeight: CGFloat) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                controlsPanel
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: maxHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        } else {
            controlsPanel
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlsPanel: some View {
        VStack(spacing: 12) {
            WorkspaceToolbar {
                captureStatus
            } actions: {
                captureActions
            }

            filterControls

        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var captureActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                captureToggleButton
                pauseButton
                exportButton
                outputMenu
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 4) {
                captureToggleButton
                pauseButton
                exportButton
                outputMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captureStatus: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    captureStatusIdentity
                    captureStatusCount
                }
            } else {
                HStack(spacing: 8) {
                    captureStatusIdentity
                    Spacer(minLength: 8)
                    captureStatusCount
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var captureStatusIdentity: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .symbolEffect(
                    .pulse,
                    isActive: store.isRunning && !store.isPaused && !reduceMotion
                )

            Text(statusTitle)
                .font(.subheadline.weight(.semibold))

            if store.isPaused, store.newEntryCount > 0 {
                Text("\(store.newEntryCount) new")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureStatusCount: some View {
        Text(store.droppedCount == 0
            ? "\(store.filteredEntries.count) of \(store.entries.count)"
            : "\(store.filteredEntries.count) of \(store.entries.count) · \(store.droppedCount) dropped")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "Showing \(store.filteredEntries.count) of \(store.entries.count) log entries"
            )
    }

    private var captureToggleButton: some View {
        Button {
            if store.isRunning {
                store.send(.stopLogcat)
            } else {
                store.send(.startLogcat)
            }
        } label: {
            Label(
                store.isRunning ? String(localized: "Stop") : String(localized: "Start"),
                systemImage: store.isRunning ? "stop.fill" : "play.fill"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(store.isRunning ? .red : .accentColor)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(
            store.isRunning ? String(localized: "Stop log capture") : String(localized: "Start log capture")
        )
        .accessibilityIdentifier("logcat.primary.capture")
    }

    private var pauseButton: some View {
        Button {
            store.send(.togglePause)
        } label: {
            Label(
                store.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                systemImage: store.isPaused ? "play.fill" : "pause.fill"
            )
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .disabled(!store.isRunning)
        .accessibilityLabel(
            store.isPaused ? String(localized: "Resume log display") : String(localized: "Pause log display")
        )
        .accessibilityHint("Capture continues while the display is paused")
    }

    private var outputMenu: some View {
        Menu {
            Button("Clear Logs", systemImage: "trash", role: .destructive) {
                store.send(.clearLog)
            }
            .disabled(store.entries.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Log actions")
        .accessibilityHint("Contains the clear command")
    }

    private var exportButton: some View {
        Menu {
            Button(LogcatExportScope.filtered.localizedTitle) { store.send(.prepareExport(.filtered)) }
                .disabled(store.filteredEntries.isEmpty)
            Button(LogcatExportScope.retained.localizedTitle) { store.send(.prepareExport(.retained)) }
                .disabled(store.entries.isEmpty)
            Button(LogcatExportScope.fromSelection.localizedTitle) { store.send(.prepareExport(.fromSelection)) }
                .disabled(store.selectedEntryID == nil)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityLabel("Review log export")
    }

    private var filterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchField
                filterButton
            }

            VStack(spacing: 8) {
                searchField
                filterButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Filter by tag or message", text: $store.filterText)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityLabel("Filter logs")
                .accessibilityIdentifier("logcat.search")

            if !store.filterText.isEmpty {
                Button {
                    store.send(.binding(.set(\.filterText, "")))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 32, minHeight: 44)
                .accessibilityLabel("Clear log filter")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: IADBDesign.controlRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: IADBDesign.controlRadius)
                .stroke(Color.primary.opacity(0.07))
        }
    }

    private var levelMenu: some View {
        FilterSummaryButton(
            "Level",
            summary: selectedLevelTitle,
            activeCount: store.selectedLevel == nil ? 0 : 1
        ) {
            Button("All Levels") {
                store.send(.binding(.set(\.selectedLevel, nil)))
            }
            Divider()
            ForEach(
                [
                    LogEntry.LogLevel.verbose,
                    .debug,
                    .info,
                    .warning,
                    .error,
                    .fatal
                ],
                id: \.rawValue
            ) { level in
                Button("\(level.rawValue): \(levelName(level))") {
                    store.send(.binding(.set(\.selectedLevel, level)))
                }
            }
        }
        .accessibilityLabel("Log level, \(selectedLevelTitle)")
        .accessibilityIdentifier("logcat.filter")
    }

    private var filterButton: some View {
        Button {
            isShowingFilters = true
        } label: {
            Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Filter logs, \(filterSummary)")
        .accessibilityIdentifier("logcat.filter")
    }

    private var filterSummary: String {
        var count = store.filter.levels.count
        if !store.filter.query.isEmpty { count += 1 }
        if !store.filter.includedTags.isEmpty { count += 1 }
        if !store.filter.excludedTerms.isEmpty { count += 1 }
        if store.filter.pid != nil { count += 1 }
        if let presetID = store.appliedPresetID,
           let preset = store.savedPresets.first(where: { $0.id == presetID }),
           !store.hasUnsavedFilter {
            return preset.name
        }
        return count == 0 ? String(localized: "Filter") : String(localized: "\(count) filters")
    }

    @ViewBuilder
    private var logContent: some View {
        if horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize {
            LogcatTableView(store: store)
        } else if store.filteredEntries.isEmpty {
            emptyLogState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.filteredEntries) { entry in
                            LogEntryRow(
                                entry: entry,
                                isSelected: store.selectedEntryID == entry.id,
                                isBookmarked: store.bookmarkedEntryIDs.contains(entry.id),
                                onSelect: {
                                    isSearchFocused = false
                                    store.send(.selectEntry(store.selectedEntryID == entry.id ? nil : entry.id))
                                },
                                onBookmark: { store.send(.toggleBookmark(entry.id)) }
                            )
                                .id(entry.id)
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("logcat.list")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { _ in
                    if !store.isPaused { store.send(.togglePause) }
                })
                .onChange(of: store.filteredEntries.count) { _, _ in
                    if store.autoScroll, !voiceOverEnabled, let last = store.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyLogState: some View {
        if store.isRunning && store.isPaused {
            ConsoleEmptyState(
                icon: "pause.circle",
                title: "Display Paused",
                message: store.newEntryCount == 0
                    ? String(localized: "Capture continues while viewport follow is paused.")
                    : String(localized: "\(store.newEntryCount) new entries are retained. Resume to follow the latest row."),
                actionTitle: "Resume",
                action: { store.send(.togglePause) }
            )
        } else if hasActiveFilters && !store.entries.isEmpty {
            ConsoleEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matching Logs",
                message: String(localized: "Try a different search term or include more log levels."),
                actionTitle: "Clear Filters",
                action: clearFilters
            )
        } else if store.isRunning {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for log output…")
                    .font(.headline)
                Text("Capture is live. Entries will appear here as the device emits them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Log capture is live, waiting for output")
        } else if hasActiveFilters {
            ConsoleEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matching Logs",
                message: String(localized: "Clear the current filters or start a new capture."),
                actionTitle: "Clear Filters",
                action: clearFilters
            )
        } else {
            ConsoleEmptyState(
                icon: "text.alignleft",
                title: "No Logs Yet",
                message: String(localized: "Start capture to stream Android logcat output in real time."),
                actionTitle: "Start Capture",
                action: { store.send(.startLogcat) }
            )
        }
    }

    private var statusTitle: String {
        switch store.captureState {
        case .starting: return String(localized: "Capture starting")
        case .live: return String(localized: "Capture live")
        case .stopped: return String(localized: "Capture stopped")
        case .failed: return String(localized: "Capture failed")
        }
    }

    private var statusIcon: String {
        switch store.captureState {
        case .starting: return "clock"
        case .live: return "record.circle.fill"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch store.captureState {
        case .starting: return .orange
        case .live: return .green
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusAccessibilityLabel: String {
        let count = String(localized: "Showing \(store.filteredEntries.count) of \(store.entries.count) log entries.")
        let dropped = store.droppedCount == 0
            ? ""
            : String(localized: " \(store.droppedCount) older entries dropped.")
        return String(localized: "\(statusTitle). \(count)\(dropped)")
    }

    private var followStatus: some View {
        HStack {
            Spacer()
            Button {
                if store.isPaused { store.send(.togglePause) }
            } label: {
                Label(
                    store.isPaused
                        ? (store.newEntryCount == 0
                            ? String(localized: "Paused")
                            : String(localized: "\(store.newEntryCount) new"))
                        : String(localized: "Following"),
                    systemImage: store.isPaused ? "pause.circle" : "arrow.down.to.line"
                )
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!store.isPaused)
            .accessibilityHint(
                store.isPaused
                    ? String(localized: "Resumes viewport follow. Capture is still running.")
                    : String(localized: "Viewport follows the latest retained log")
            )
            Spacer()
        }
        .padding(.horizontal)
        .background(.bar)
    }

    private var filterSheetBinding: Binding<Bool> {
        Binding(get: { isShowingFilters }, set: { isShowingFilters = $0 })
    }

    private var exportReviewBinding: Binding<Bool> {
        Binding(
            get: { store.exportReview != nil },
            set: { if !$0 { store.send(.cancelExport) } }
        )
    }

    private var selectedLevelTitle: String {
        guard let level = store.selectedLevel else { return String(localized: "All levels") }
        return levelName(level)
    }

    private var hasActiveFilters: Bool {
        !store.filter.query.isEmpty || !store.filter.levels.isEmpty ||
            !store.filter.includedTags.isEmpty || !store.filter.excludedTerms.isEmpty ||
            store.filter.pid != nil
    }

    private func clearFilters() {
        store.send(.binding(.set(\.filter, .empty)))
    }

    private func levelName(_ level: LogEntry.LogLevel) -> String {
        switch level {
        case .verbose: return String(localized: "Verbose")
        case .debug: return String(localized: "Debug")
        case .info: return String(localized: "Info")
        case .warning: return String(localized: "Warning")
        case .error: return String(localized: "Error")
        case .fatal: return String(localized: "Fatal")
        case .silent: return String(localized: "Silent")
        case .unknown: return String(localized: "Unknown")
        }
    }

    @ToolbarContentBuilder
    private var logcatToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $store.autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .accessibilityLabel("Auto-scroll logs")
            .accessibilityValue(store.autoScroll ? String(localized: "On") : String(localized: "Off"))
        }
    }
}

private struct ConsoleEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    init(
        icon: String,
        title: LocalizedStringResource,
        message: String,
        actionTitle: LocalizedStringResource,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = String(localized: title)
        self.message = message
        self.actionTitle = String(localized: actionTitle)
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ShareTextSheet: UIViewControllerRepresentable {
    let text: String
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LogEntryRow: View {
    let entry: LogEntry
    let isSelected: Bool
    let isBookmarked: Bool
    let onSelect: () -> Void
    let onBookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.message)
                    .font(.caption.monospaced())
                    .lineLimit(isSelected ? nil : 3)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Bookmarked")
                }
            }

            HStack(spacing: 8) {
                Text(entry.level.rawValue).foregroundStyle(levelColor).fontWeight(.bold)
                Text(entry.tag.isEmpty ? String(localized: "Unparsed") : entry.tag).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(entry.timestamp.components(separatedBy: " ").last ?? entry.timestamp)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())

            if isSelected {
                Text("\(entry.timestamp) · PID \(entry.pid) · TID \(entry.tid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { selectedActions }
                    VStack(alignment: .leading, spacing: 8) { selectedActions }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .iadbSelectionHighlight(isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("logcat.entry")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: "Copy message") {
            UIPasteboard.general.string = entry.message
            announceAccessibility("Log message copied")
        }
        .accessibilityAction(
            named: isBookmarked ? String(localized: "Remove bookmark") : String(localized: "Bookmark"),
            onBookmark
        )
    }

    private var accessibilityDescription: String {
        let tag = entry.tag.isEmpty ? String(localized: "Unparsed") : entry.tag
        var parts = [levelAccessibilityLabel, tag, entry.message]
        if !entry.timestamp.isEmpty { parts.append(entry.timestamp) }
        if !entry.pid.isEmpty { parts.append("PID \(entry.pid)") }
        if !entry.tid.isEmpty { parts.append("TID \(entry.tid)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var selectedActions: some View {
        Button("Copy Message", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = entry.message
            announceAccessibility("Log message copied")
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        Button(
            isBookmarked ? String(localized: "Unbookmark") : String(localized: "Bookmark"),
            systemImage: "bookmark",
            action: onBookmark
        )
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
    }

    private var levelAccessibilityLabel: String {
        switch entry.level {
        case .verbose: return String(localized: "Verbose")
        case .debug: return String(localized: "Debug")
        case .info: return String(localized: "Info")
        case .warning: return String(localized: "Warning")
        case .error: return String(localized: "Error")
        case .fatal: return String(localized: "Fatal")
        case .silent: return String(localized: "Silent")
        case .unknown: return String(localized: "Unknown level")
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .verbose: return .secondary
        case .debug: return .blue
        case .info: return .green
        case .warning: return .orange
        case .error, .fatal: return .red
        case .silent, .unknown: return .primary
        }
    }
}

private struct LogcatTableView: View {
    @Bindable var store: StoreOf<LogcatFeature>

    var body: some View {
        Group {
            if store.showsProcessColumn {
                tableWithProcess
            } else {
                tableWithoutProcess
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Toggle("PID/TID column", isOn: $store.showsProcessColumn)
            }
        }
    }

    private var tableWithProcess: some View {
        Table(store.filteredEntries, selection: selectedBinding) {
            TableColumn("Time") { Text($0.timestamp).font(.caption.monospacedDigit()) }
                .width(min: 118, ideal: 142)
            TableColumn("Level") { Text($0.level.rawValue).font(.caption.monospaced().bold()) }
                .width(48)
            TableColumn("PID/TID") { Text("\($0.pid)/\($0.tid)").font(.caption.monospacedDigit()) }
                .width(min: 78, ideal: 96)
            TableColumn("Tag") { Text($0.tag).font(.caption.monospaced()).lineLimit(1) }
                .width(min: 100, ideal: 150)
            TableColumn("Message") { Text($0.message).font(.caption.monospaced()).lineLimit(2) }
                .width(min: 220, ideal: 420)
        }
        .accessibilityIdentifier("logcat.table")
    }

    private var tableWithoutProcess: some View {
        Table(store.filteredEntries, selection: selectedBinding) {
            TableColumn("Time") { Text($0.timestamp).font(.caption.monospacedDigit()) }
                .width(min: 118, ideal: 142)
            TableColumn("Level") { Text($0.level.rawValue).font(.caption.monospaced().bold()) }
                .width(48)
            TableColumn("Tag") { Text($0.tag).font(.caption.monospaced()).lineLimit(1) }
                .width(min: 120, ideal: 180)
            TableColumn("Message") { Text($0.message).font(.caption.monospaced()).lineLimit(2) }
                .width(min: 260, ideal: 480)
        }
        .accessibilityIdentifier("logcat.table")
    }

    private var selectedBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedEntryID },
            set: { store.send(.selectEntry($0)) }
        )
    }
}

struct LogcatInspectorView: View {
    let store: StoreOf<LogcatFeature>
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.message).font(.body.monospaced()).textSelection(.enabled)
                VStack(spacing: 0) {
                    TechnicalRow(label: "Timestamp", value: entry.timestamp, monospacedValue: true)
                    Divider()
                    TechnicalRow(label: "Level", value: entry.level.rawValue)
                    Divider()
                    TechnicalRow(label: "Tag", value: entry.tag, monospacedValue: true)
                    Divider()
                    TechnicalRow(label: "PID / TID", value: "\(entry.pid) / \(entry.tid)", monospacedValue: true)
                }
                Button("Copy Message", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.message
                    announceAccessibility("Log message copied")
                }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                Button(
                    store.bookmarkedEntryIDs.contains(entry.id)
                        ? String(localized: "Remove Bookmark")
                        : String(localized: "Bookmark"),
                    systemImage: "bookmark"
                ) { store.send(.toggleBookmark(entry.id)) }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
            .padding()
        }
        .navigationTitle("Log Details")
    }
}

private struct LogcatExportReviewView: View {
    @Bindable var store: StoreOf<LogcatFeature>

    var body: some View {
        NavigationStack {
            Form {
                if let review = store.exportReview {
                    Section("Scope") {
                        LabeledContent("Range", value: review.scope.localizedTitle)
                            .accessibilityIdentifier("logcat.export.scope")
                        LabeledContent("Entries", value: "\(review.entries.count)")
                    }
                    Section("Privacy") {
                        Toggle("Include device metadata", isOn: metadataBinding)
                        Toggle("Redact endpoint and serial", isOn: redactionBinding)
                    }
                }
            }
            .navigationTitle("Export Logs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelExport) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { store.send(.confirmExport) }
                        .disabled(store.exportReview?.entries.isEmpty != false)
                }
            }
        }
    }

    private var metadataBinding: Binding<Bool> {
        Binding(
            get: { store.exportReview?.includeDeviceMetadata ?? true },
            set: { store.send(.setExportOptions(includeDeviceMetadata: $0, redactSensitiveValues: store.exportReview?.redactSensitiveValues ?? true)) }
        )
    }

    private var redactionBinding: Binding<Bool> {
        Binding(
            get: { store.exportReview?.redactSensitiveValues ?? true },
            set: { store.send(.setExportOptions(includeDeviceMetadata: store.exportReview?.includeDeviceMetadata ?? true, redactSensitiveValues: $0)) }
        )
    }
}

private struct LogcatFilterView: View {
    @Bindable var store: StoreOf<LogcatFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Levels") {
                    ForEach(LogEntry.LogLevel.allCases.filter { $0 != .silent && $0 != .unknown }, id: \.self) { level in
                        Toggle(levelName(level), isOn: levelBinding(level))
                    }
                }
                Section("Scope") {
                    TextField("Included tags, comma separated", text: tagsBinding)
                    TextField("Excluded terms, comma separated", text: excludedBinding)
                    TextField("PID", text: pidBinding).keyboardType(.numberPad)
                }
                Section("Presets") {
                    ForEach(store.savedPresets) { preset in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Preset name", text: presetNameBinding(preset))
                            HStack {
                                Button("Apply") { store.send(.applyPreset(preset)) }
                                Button("Duplicate") { store.send(.duplicatePreset(preset.id)) }
                                Button("Delete", role: .destructive) { store.send(.deletePreset(preset.id)) }
                            }
                            .buttonStyle(.borderless)
                            if preset.isGlobal { Text("Global").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TextField("New preset name", text: $store.presetNameInput)
                    Toggle("Available on all devices", isOn: $store.newPresetIsGlobal)
                    Button("Save Current Filter") { store.send(.savePreset) }
                        .disabled(store.presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Filter Logs")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private func levelBinding(_ level: LogEntry.LogLevel) -> Binding<Bool> {
        Binding(
            get: { store.filter.levels.contains(level) },
            set: { enabled in
                var levels = store.filter.levels
                if enabled { levels.insert(level) } else { levels.remove(level) }
                store.send(.binding(.set(\.filter.levels, levels)))
            }
        )
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { store.filter.includedTags.sorted().joined(separator: ", ") },
            set: { store.send(.binding(.set(\.filter.includedTags, Set(parseList($0))))) }
        )
    }

    private var excludedBinding: Binding<String> {
        Binding(
            get: { store.filter.excludedTerms.joined(separator: ", ") },
            set: { store.send(.binding(.set(\.filter.excludedTerms, parseList($0)))) }
        )
    }

    private var pidBinding: Binding<String> {
        Binding(
            get: { store.filter.pid.map(String.init) ?? "" },
            set: { store.send(.binding(.set(\.filter.pid, Int($0)))) }
        )
    }

    private func presetNameBinding(_ preset: LogcatPreset) -> Binding<String> {
        Binding(get: { preset.name }, set: { store.send(.renamePreset(preset.id, $0)) })
    }

    private func parseList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func levelName(_ level: LogEntry.LogLevel) -> String {
        switch level {
        case .verbose: String(localized: "Verbose")
        case .debug: String(localized: "Debug")
        case .info: String(localized: "Info")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        case .fatal: String(localized: "Fatal")
        case .silent: String(localized: "Silent")
        case .unknown: String(localized: "Unknown")
        }
    }
}
