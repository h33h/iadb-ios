import SwiftUI
import UIKit
import ComposableArchitecture

struct ShellView: View {
    @Bindable var store: StoreOf<ShellFeature>
    let isEmbeddedInNavigationStack: Bool
    let focusRequestID: Int

    @FocusState private var isInputFocused: Bool
    @State private var showingClearHistoryConfirmation = false

    init(
        store: StoreOf<ShellFeature>,
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
                shellContent
                    .toolbar { shellToolbar }
            } else {
                NavigationStack {
                    shellContent
                        .navigationTitle("Shell")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { shellToolbar }
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onChange(of: focusRequestID) { oldValue, newValue in
            guard oldValue != newValue else { return }
            isInputFocused = true
        }
        .onChange(of: store.isExecuting) { wasExecuting, isExecuting in
            if let announcement = ShellFeature.accessibilityAnnouncement(
                wasExecuting: wasExecuting,
                isExecuting: isExecuting,
                execution: store.activeExecution
            ) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .confirmationDialog(
            "Clear Shell History?",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                store.send(.clearHistory)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes command output saved for the current device.")
        }
        .confirmationDialog(
            "Reuse Command on Current Device?",
            isPresented: historyReuseConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Reuse on Current Device") {
                store.send(.confirmHistoryReuse)
                isInputFocused = true
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelHistoryReuse)
            }
        } message: {
            Text("This command was saved for another or an unknown device. Review it before running it on the current target.")
        }
    }

    private var shellContent: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                StatusBannerView(
                    style: .error,
                    message: error,
                    onDismiss: { store.send(.dismissError) }
                )
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if !store.pinnedCommands.isEmpty {
                pinnedCommands
            }

            if store.isExecuting, let execution = store.activeExecution {
                ActiveCommandExecutionView(execution: execution)
            }

            Group {
                if store.visibleHistory.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            commandComposer
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("workspace.shell")
    }

    private var pinnedCommands: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(store.pinnedCommands, id: \.self) { command in
                    HStack(spacing: 8) {
                        Button {
                            store.send(.executeQuickCommand(command))
                        } label: {
                            Text(command)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isExecuting)
                        .accessibilityLabel("Run pinned command, \(command)")

                        Button {
                            store.send(.togglePinnedCommand(command))
                        } label: {
                            Image(systemName: "pin.slash")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Unpin command, \(command)")
                    }
                    if command != store.pinnedCommands.last { Divider() }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Pinned", systemImage: "pin.fill")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Pinned Commands")
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("Command Runner", systemImage: "terminal")
                } description: {
                    Text("Each command runs in a new shell session. Run a command below or start with a device diagnostic.")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick commands")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 148, maximum: 220),
                                spacing: 10,
                                alignment: .leading
                            )
                        ],
                        spacing: 10
                    ) {
                        ForEach(store.suggestions, id: \.self) { command in
                            QuickCommandChip(
                                command: command,
                                isPinned: store.pinnedCommands.contains(command),
                                onRun: { store.send(.executeQuickCommand(command)) },
                                onTogglePin: { store.send(.togglePinnedCommand(command)) }
                            )
                            .disabled(store.isExecuting)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.top)
        .accessibilityIdentifier("shell.history")
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.visibleHistory) { entry in
                    ShellEntryView(
                        entry: entry,
                        isPinned: store.pinnedCommands.contains(entry.command),
                        isSelected: store.selectedHistoryID == entry.id,
                        onSelect: {
                            isInputFocused = false
                            store.send(.selectHistory(store.selectedHistoryID == entry.id ? nil : entry.id))
                        },
                        onReuse: {
                            store.send(.requestHistoryReuse(entry.id))
                            if entry.originDeviceID == store.activeDeviceID {
                                isInputFocused = true
                            }
                        },
                        onTogglePin: {
                            store.send(.togglePinnedCommand(entry.command))
                        }
                    )
                }
            }
            .padding(.horizontal)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { isInputFocused = false }
        .defaultScrollAnchor(.top)
    }

    private var commandComposer: some View {
        HStack(spacing: 10) {
            TextField("Enter a one-shot command", text: $store.commandInput, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($isInputFocused)
                .accessibilityLabel("Shell command")
                .accessibilityIdentifier("shell.command")
                .onSubmit {
                    runCommand()
                }

            if store.isExecuting {
                Button {
                    store.send(.cancelExecution)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityLabel("Stop command")
                .accessibilityIdentifier("shell.primary.stop")
                .accessibilityHint("Cancels the command currently running")
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    runCommand()
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedCommandInput.isEmpty)
                .accessibilityLabel("Run command")
                .accessibilityIdentifier("shell.primary.run")
                .accessibilityHint("Executes the entered command on the connected device")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private var trimmedCommandInput: String {
        store.commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var historyReuseConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.pendingHistoryReuse != nil },
            set: { if !$0 { store.send(.cancelHistoryReuse) } }
        )
    }

    private func runCommand() {
        guard !trimmedCommandInput.isEmpty, !store.isExecuting else { return }
        isInputFocused = false
        store.send(.executeCommand)
    }

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !store.visibleHistory.isEmpty {
                Menu {
                    Button("Clear Shell History", systemImage: "trash", role: .destructive) {
                        showingClearHistoryConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Shell actions")
            }
        }
    }
}

private struct ActiveCommandExecutionView: View {
    let execution: ShellFeature.CommandExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(execution.command)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if execution.usedLegacyFallback {
                Label(
                    "Legacy shell: stderr separation and live output are unavailable.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !execution.stdout.isEmpty {
                Text(execution.stdout)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !execution.stderr.isEmpty {
                Text(execution.stderr)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if execution.wasTruncated {
                Label("Output truncated at 128 KiB", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Running shell command \(execution.command). Live output updates without moving focus.")
    }
}

struct ShellEntryView: View {
    let entry: ShellHistoryEntry
    let isPinned: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onReuse: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: entry.isError ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(entry.isError ? .red : .secondary)
                    .accessibilityHidden(true)

                Text(entry.command)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }

                Spacer(minLength: 8)

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                executionMetadata

                if !entry.stdout.isEmpty {
                    Text(entry.stdout)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !entry.stderr.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("stderr")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(entry.stderr)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if entry.stdout.isEmpty, entry.stderr.isEmpty {
                    Text(
                        entry.exitCode == nil
                            ? String(localized: "Command interrupted")
                            : String(localized: "Completed without output")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("shell.history.entry")
            .accessibilityAction(.default, onSelect)
            .accessibilityAction(named: "Reuse command", onReuse)
            .accessibilityAction(
                named: isPinned ? String(localized: "Unpin command") : String(localized: "Pin command"),
                onTogglePin
            )
            .accessibilityAction(named: "Copy output") {
                UIPasteboard.general.string = entry.output
                announceAccessibility("Command output copied")
            }
            .contextMenu { entryContextMenu }

            if isSelected { selectedActions }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .iadbSelectionHighlight(isSelected: isSelected)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var entryContextMenu: some View {
            Button(action: onReuse) {
                Label("Reuse Command", systemImage: "arrow.uturn.backward.circle")
            }
            Button(action: onTogglePin) {
                Label(
                    isPinned ? String(localized: "Unpin Command") : String(localized: "Pin Command"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                UIPasteboard.general.string = entry.output
                announceAccessibility("Command output copied")
            } label: {
                Label("Copy Output", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.command
                announceAccessibility("Command copied")
            } label: {
                Label("Copy Command", systemImage: "terminal")
            }
    }

    private var executionMetadata: some View {
        HStack(spacing: 10) {
            Text(
                entry.exitCode.map { String(localized: "Exit \($0)") }
                    ?? String(localized: "Interrupted")
            )
            if let duration = entry.duration {
                Text(duration.formatted(.number.precision(.fractionLength(2))) + " s")
            }
            if entry.wasTruncated { Label("Truncated", systemImage: "scissors") }
            if entry.usedLegacyFallback { Label("Legacy", systemImage: "exclamationmark.triangle") }
            if entry.originDeviceID == DeviceIdentity.unknownID {
                Label("Unknown device", systemImage: "questionmark.circle")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var selectedActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Reuse", systemImage: "arrow.uturn.backward", action: onReuse)
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = entry.output
            announceAccessibility("Command output copied")
        }
        .frame(minHeight: 44)
        .buttonStyle(.bordered)
        Button(
            isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
            systemImage: isPinned ? "pin.slash" : "pin",
            action: onTogglePin
        )
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
    }

    private var accessibilitySummary: String {
        let exit = entry.exitCode.map { String(localized: "exit code \($0)") }
            ?? String(localized: "interrupted")
        let stdoutSummary = entry.stdout.isEmpty
            ? String(localized: "no standard output")
            : String(localized: "standard output available")
        let stderrSummary = entry.stderr.isEmpty
            ? String(localized: "no standard error")
            : String(localized: "standard error available")
        return String(localized: "Shell command \(entry.command), \(exit), \(stdoutSummary), \(stderrSummary)")
    }
}

struct ShellHistoryInspectorView: View {
    let store: StoreOf<ShellFeature>
    let entry: ShellHistoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.command)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)

                VStack(spacing: 0) {
                    TechnicalRow(
                        label: "Exit code",
                        value: entry.exitCode.map(String.init) ?? String(localized: "Interrupted")
                    )
                    Divider()
                    TechnicalRow(
                        label: "Duration",
                        value: entry.duration.map {
                            String(localized: "\($0.formatted(.number.precision(.fractionLength(2)))) s")
                        } ?? String(localized: "Unavailable")
                    )
                    Divider()
                    TechnicalRow(
                        label: "Output",
                        value: entry.wasTruncated ? String(localized: "Truncated") : String(localized: "Complete")
                    )
                    Divider()
                    TechnicalRow(
                        label: "Protocol",
                        value: entry.usedLegacyFallback ? String(localized: "Legacy shell") : "Shell v2"
                    )
                }

                if !entry.stdout.isEmpty {
                    outputSection("stdout", text: entry.stdout, color: .primary)
                }
                if !entry.stderr.isEmpty {
                    outputSection("stderr", text: entry.stderr, color: .red)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actionButtons }
                    VStack(alignment: .leading, spacing: 8) { actionButtons }
                }
            }
            .padding()
        }
        .navigationTitle("Command Output")
    }

    private func outputSection(_ title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Reuse", systemImage: "arrow.uturn.backward") {
            store.send(.requestHistoryReuse(entry.id))
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = entry.output
            announceAccessibility("Command output copied")
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        Button(
            store.pinnedCommands.contains(entry.command)
                ? String(localized: "Unpin")
                : String(localized: "Pin"),
            systemImage: store.pinnedCommands.contains(entry.command) ? "pin.slash" : "pin"
        ) {
            store.send(.togglePinnedCommand(entry.command))
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }
}

struct QuickCommandChip: View {
    let command: String
    let isPinned: Bool
    let onRun: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRun) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.tint)

                    Text(command)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .layoutPriority(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run quick command, \(command)")

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(
                isPinned
                    ? String(localized: "Unpin quick command, \(command)")
                    : String(localized: "Pin quick command, \(command)")
            )
            .accessibilityValue(
                isPinned ? String(localized: "Pinned") : String(localized: "Not pinned")
            )
            .accessibilityAddTraits(isPinned ? .isSelected : [])
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            isPinned ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isPinned ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.06))
        }
        .contextMenu {
            Button(action: onTogglePin) {
                Label(
                    isPinned ? String(localized: "Unpin Command") : String(localized: "Pin Command"),
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
    }
}
