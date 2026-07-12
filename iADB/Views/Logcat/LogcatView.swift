import SwiftUI
import UIKit
import ComposableArchitecture

struct LogcatView: View {
    @Bindable var store: StoreOf<LogcatFeature>
    let isEmbeddedInNavigationStack: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showingExportSheet = false
    @State private var exportText = ""
    @State private var isShowingPresetEditor = false

    init(
        store: StoreOf<LogcatFeature>,
        isEmbeddedInNavigationStack: Bool = false
    ) {
        self.store = store
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
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
        .sheet(isPresented: $showingExportSheet, onDismiss: {
            exportText = ""
            store.send(.clearExport)
        }) {
            ShareTextSheet(text: exportText, fileName: "logcat.txt")
        }
    }

    private var logcatContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    StatusBannerView(
                        style: .error,
                        message: error,
                        actionTitle: "Retry",
                        onDismiss: { store.send(.dismissError) },
                        onAction: { store.send(.startLogcat) }
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                controlsRegion(maxHeight: geometry.size.height * 0.62)

                Divider()

                logContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
            captureStatus
            captureActions

            filterControls

            if !store.savedPresets.isEmpty {
                savedPresets
            }

            presetEditor
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
                outputMenu
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 4) {
                captureToggleButton
                pauseButton
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

            if store.isPaused, !store.pauseBuffer.isEmpty {
                Text("\(store.pauseBuffer.count) buffered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureStatusCount: some View {
        Text("\(store.filteredEntries.count) of \(store.entries.count)")
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
                store.isRunning ? "Stop" : "Start",
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
        .accessibilityLabel(store.isRunning ? "Stop log capture" : "Start log capture")
    }

    private var pauseButton: some View {
        Button {
            store.send(.togglePause)
        } label: {
            Label(
                store.isPaused ? "Resume" : "Pause",
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
        .accessibilityLabel(store.isPaused ? "Resume log display" : "Pause log display")
        .accessibilityHint("Capture continues while the display is paused")
    }

    private var outputMenu: some View {
        Menu {
            Button("Export Logs", systemImage: "square.and.arrow.up") {
                exportText = LogcatFeature.exportString(store.filteredEntries)
                showingExportSheet = true
            }
            .disabled(store.filteredEntries.isEmpty)

            Button("Clear Logs", systemImage: "trash", role: .destructive) {
                store.send(.clearLog)
            }
            .disabled(store.entries.isEmpty && store.pauseBuffer.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Log actions")
        .accessibilityHint("Contains export and clear commands")
    }

    private var filterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchField
                levelMenu
            }

            VStack(spacing: 8) {
                searchField
                levelMenu
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityLabel("Filter logs")

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
        Menu {
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
        } label: {
            Label(selectedLevelTitle, systemImage: "line.3.horizontal.decrease")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
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
        .accessibilityLabel("Log level, \(selectedLevelTitle)")
    }

    private var savedPresets: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Saved filters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Menu {
                    ForEach(store.savedPresets) { preset in
                        Button(role: .destructive) {
                            store.send(.deletePreset(preset.id))
                        } label: {
                            Label("Delete \(preset.name)", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Manage saved filters")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(store.savedPresets) { preset in
                        Button {
                            store.send(.applyPreset(preset))
                        } label: {
                            Label(preset.name, systemImage: "line.3.horizontal.decrease.circle")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 34)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Apply saved filter, \(preset.name)")
                        .contextMenu {
                            Button(role: .destructive) {
                                store.send(.deletePreset(preset.id))
                            } label: {
                                Label("Delete Preset", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .frame(height: 44)
        }
    }

    private var presetEditor: some View {
        DisclosureGroup(isExpanded: $isShowingPresetEditor) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    presetNameField
                    savePresetButton
                }

                VStack(spacing: 8) {
                    presetNameField
                    savePresetButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Save current filter", systemImage: "bookmark")
                .font(.subheadline.weight(.medium))
        }
        .accessibilityHint("Saves the current text and level filters for reuse")
    }

    private var presetNameField: some View {
        TextField("Preset name", text: $store.presetNameInput)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.done)
            .accessibilityLabel("Preset name")
    }

    private var savePresetButton: some View {
        Button("Save Preset") {
            store.send(.savePreset)
            isShowingPresetEditor = false
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(store.presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var logContent: some View {
        if store.filteredEntries.isEmpty {
            emptyLogState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: store.filteredEntries.count) { _, _ in
                    if store.autoScroll, let last = store.filteredEntries.last {
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
                message: store.pauseBuffer.isEmpty
                    ? "New log entries will be buffered until you resume."
                    : "\(store.pauseBuffer.count) entries are buffered and ready to display.",
                actionTitle: "Resume",
                action: { store.send(.togglePause) }
            )
        } else if hasActiveFilters && !store.entries.isEmpty {
            ConsoleEmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matching Logs",
                message: "Try a different search term or include more log levels.",
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
                message: "Clear the current filters or start a new capture.",
                actionTitle: "Clear Filters",
                action: clearFilters
            )
        } else {
            ConsoleEmptyState(
                icon: "text.alignleft",
                title: "No Logs Yet",
                message: "Start capture to stream Android logcat output in real time.",
                actionTitle: "Start Capture",
                action: { store.send(.startLogcat) }
            )
        }
    }

    private var statusTitle: String {
        if store.isPaused { return "Display paused" }
        if store.isRunning { return "Capture live" }
        return "Capture stopped"
    }

    private var statusIcon: String {
        if store.isPaused { return "pause.circle.fill" }
        if store.isRunning { return "record.circle.fill" }
        return "stop.circle"
    }

    private var statusColor: Color {
        if store.isPaused { return .orange }
        if store.isRunning { return .green }
        return .secondary
    }

    private var statusAccessibilityLabel: String {
        let count = "Showing \(store.filteredEntries.count) of \(store.entries.count) log entries."
        if store.isPaused {
            return "Log display paused. \(store.pauseBuffer.count) entries buffered. \(count)"
        }
        return "\(statusTitle). \(count)"
    }

    private var selectedLevelTitle: String {
        guard let level = store.selectedLevel else { return "All levels" }
        return levelName(level)
    }

    private var hasActiveFilters: Bool {
        !store.filterText.isEmpty || store.selectedLevel != nil
    }

    private func clearFilters() {
        store.send(.binding(.set(\.filterText, "")))
        store.send(.binding(.set(\.selectedLevel, nil)))
    }

    private func levelName(_ level: LogEntry.LogLevel) -> String {
        switch level {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .fatal: return "Fatal"
        case .silent: return "Silent"
        case .unknown: return "Unknown"
        }
    }

    @ToolbarContentBuilder
    private var logcatToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $store.autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .accessibilityLabel("Auto-scroll logs")
            .accessibilityValue(store.autoScroll ? "On" : "Off")
        }
    }
}

private struct ConsoleEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

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
    @State private var isExpanded = false
    @State private var collapsedMessageHeight: CGFloat = 0
    @State private var fullMessageHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.level.rawValue)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(levelColor)
                .frame(width: 28, height: 28)
                .background(levelColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(levelAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.tag.isEmpty ? "Unparsed" : entry.tag)
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(entry.tag.isEmpty ? Color.secondary : Color.accentColor)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if !entry.timestamp.isEmpty {
                        Text(entry.timestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Menu {
                        Button {
                            copyEntry()
                        } label: {
                            Label("Copy Log Entry", systemImage: "doc.on.doc")
                        }

                        if canExpand {
                            Button {
                                isExpanded.toggle()
                            } label: {
                                Label(
                                    isExpanded ? "Show Less" : "Show Full Message",
                                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Actions for log entry")
                }

                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(shouldCollapseMessage ? 4 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        messageMeasurementText(lineLimit: 4)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: CollapsedLogMessageHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            }
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .background {
                        messageMeasurementText(lineLimit: nil)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FullLogMessageHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            }
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .onPreferenceChange(CollapsedLogMessageHeightKey.self) { height in
                        collapsedMessageHeight = height
                    }
                    .onPreferenceChange(FullLogMessageHeightKey.self) { height in
                        fullMessageHeight = height
                    }

                if canExpand {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(
                            isExpanded ? "Show less" : "Show full message",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityHint(
                        isExpanded
                            ? "Collapses this log message"
                            : "Shows this entire log message"
                    )
                }

                if !entry.pid.isEmpty {
                    Text("PID \(entry.pid)  ·  TID \(entry.tid)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAction(named: "Copy log entry") {
            copyEntry()
        }
        .contextMenu {
            Button {
                copyEntry()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var accessibilityDescription: String {
        let tag = entry.tag.isEmpty ? "Unparsed" : entry.tag
        var parts = [levelAccessibilityLabel, tag, entry.message]
        if !entry.timestamp.isEmpty { parts.append(entry.timestamp) }
        if !entry.pid.isEmpty { parts.append("PID \(entry.pid)") }
        if !entry.tid.isEmpty { parts.append("TID \(entry.tid)") }
        return parts.joined(separator: ", ")
    }

    private var canExpand: Bool {
        hasMeasuredMessage && fullMessageHeight > collapsedMessageHeight + 0.5
    }

    private var hasMeasuredMessage: Bool {
        collapsedMessageHeight > 0 && fullMessageHeight > 0
    }

    private var shouldCollapseMessage: Bool {
        hasMeasuredMessage && canExpand && !isExpanded
    }

    private func messageMeasurementText(lineLimit: Int?) -> some View {
        Text(entry.message)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyEntry() {
        UIPasteboard.general.string = "\(entry.level.rawValue)/\(entry.tag): \(entry.message)"
    }

    private var levelAccessibilityLabel: String {
        switch entry.level {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .fatal: return "Fatal"
        case .silent: return "Silent"
        case .unknown: return "Unknown level"
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

private struct CollapsedLogMessageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullLogMessageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
