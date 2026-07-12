import SwiftUI
import UIKit
import ComposableArchitecture

struct ShellView: View {
    @Bindable var store: StoreOf<ShellFeature>
    let isEmbeddedInNavigationStack: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @FocusState private var isInputFocused: Bool
    @State private var showingClearHistoryConfirmation = false

    init(
        store: StoreOf<ShellFeature>,
        isEmbeddedInNavigationStack: Bool = false
    ) {
        self.store = store
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
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
            Text("This permanently removes all saved command output.")
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

            shellStatus

            if !store.pinnedCommands.isEmpty {
                pinnedCommands
            }

            Group {
                if store.history.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            commandComposer
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var shellStatus: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    shellStatusIdentity
                    shellHistoryCount
                }
            } else {
                HStack(spacing: 10) {
                    shellStatusIdentity
                    Spacer(minLength: 8)
                    shellHistoryCount
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.isExecuting ? "Shell is executing a command" : "Shell is ready")
    }

    private var shellStatusIdentity: some View {
        HStack(spacing: 7) {
            if store.isExecuting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(store.isExecuting ? "Executing command" : "Ready")
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var shellHistoryCount: some View {
        if !store.history.isEmpty {
            Label("\(store.history.count)", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(store.history.count) commands in history")
        }
    }

    private var pinnedCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pinned commands", systemImage: "pin.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(store.pinnedCommands, id: \.self) { command in
                        HStack(spacing: 0) {
                            Button {
                                store.send(.executeQuickCommand(command))
                            } label: {
                                Text(command)
                                    .font(.system(.caption, design: .monospaced, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 260, alignment: .leading)
                                    .padding(.leading, 12)
                                    .padding(.trailing, 8)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isExecuting)
                            .accessibilityLabel("Run pinned command, \(command)")
                            .accessibilityAction(named: "Edit command") {
                                editPinnedCommand(command)
                            }
                            .accessibilityAction(named: "Unpin command") {
                                store.send(.togglePinnedCommand(command))
                            }

                            Menu {
                                Button {
                                    editPinnedCommand(command)
                                } label: {
                                    Label("Edit Command", systemImage: "square.and.pencil")
                                }
                                Button {
                                    store.send(.togglePinnedCommand(command))
                                } label: {
                                    Label("Unpin", systemImage: "pin.slash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Actions for pinned command, \(command)")
                        }
                        .frame(minHeight: 44)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                        }
                        .contextMenu {
                            Button {
                                editPinnedCommand(command)
                            } label: {
                                Label("Edit Command", systemImage: "square.and.pencil")
                            }
                            Button {
                                store.send(.togglePinnedCommand(command))
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView {
                    Label("ADB Shell", systemImage: "terminal")
                } description: {
                    Text("Run a command below or start with a common device diagnostic.")
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
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(store.history) { entry in
                    ShellEntryView(
                        entry: entry,
                        isPinned: store.pinnedCommands.contains(entry.command),
                        onReuse: {
                            store.send(.useHistoryCommand(entry.command))
                            isInputFocused = true
                        },
                        onTogglePin: {
                            store.send(.togglePinnedCommand(entry.command))
                        }
                    )
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.top)
    }

    private var commandComposer: some View {
        HStack(spacing: 10) {
            Text("$")
                .font(.system(.body, design: .monospaced, weight: .bold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            TextField("Enter command...", text: $store.commandInput)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($isInputFocused)
                .accessibilityLabel("Shell command")
                .onSubmit {
                    runCommand()
                }

            if store.isExecuting {
                Button {
                    store.send(.cancelExecution)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.red, in: Circle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Stop command")
                .accessibilityHint("Cancels the command currently running")
            } else {
                Button {
                    runCommand()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor, in: Circle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(trimmedCommandInput.isEmpty)
                .accessibilityLabel("Run command")
                .accessibilityHint("Executes the entered command on the connected device")
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

    private func runCommand() {
        guard !trimmedCommandInput.isEmpty, !store.isExecuting else { return }
        isInputFocused = false
        store.send(.executeCommand)
    }

    private func editPinnedCommand(_ command: String) {
        store.send(.useHistoryCommand(command))
        isInputFocused = true
    }

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !store.history.isEmpty {
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

struct ShellEntryView: View {
    let entry: ShellHistoryEntry
    let isPinned: Bool
    let onReuse: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: entry.isError ? "exclamationmark.circle.fill" : "chevron.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(entry.isError ? .red : .green)
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

                Menu {
                    Button(action: onReuse) {
                        Label("Reuse Command", systemImage: "arrow.uturn.backward.circle")
                    }
                    Button(action: onTogglePin) {
                        Label(
                            isPinned ? "Unpin Command" : "Pin Command",
                            systemImage: isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        UIPasteboard.general.string = entry.output
                    } label: {
                        Label("Copy Output", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = entry.command
                    } label: {
                        Label("Copy Command", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Actions for \(entry.command)")
            }

            if !entry.output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if entry.isError {
                        Text("Command failed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }

                    Text(entry.output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(
                    entry.isError
                        ? Color.red.opacity(0.08)
                        : Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: IADBDesign.controlRadius, style: .continuous)
                )
            } else {
                Text("Command completed without output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
                .stroke(entry.isError ? Color.red.opacity(0.25) : Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.isError ? "Failed shell command" : "Completed shell command")
        .accessibilityAction(named: "Reuse command", onReuse)
        .accessibilityAction(named: isPinned ? "Unpin command" : "Pin command", onTogglePin)
        .accessibilityAction(named: "Copy output") {
            UIPasteboard.general.string = entry.output
        }
        .contextMenu {
            Button(action: onReuse) {
                Label("Reuse Command", systemImage: "arrow.uturn.backward.circle")
            }
            Button(action: onTogglePin) {
                Label(
                    isPinned ? "Unpin Command" : "Pin Command",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                UIPasteboard.general.string = entry.output
            } label: {
                Label("Copy Output", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.command
            } label: {
                Label("Copy Command", systemImage: "terminal")
            }
        }
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
            .accessibilityLabel(isPinned ? "Unpin quick command, \(command)" : "Pin quick command, \(command)")
            .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
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
                    isPinned ? "Unpin Command" : "Pin Command",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
    }
}
