import SwiftUI
import ComposableArchitecture

struct ShellView: View {
    @Bindable var store: StoreOf<ShellFeature>
    @FocusState private var isInputFocused: Bool
    @State private var showingClearHistoryConfirmation = false

    var body: some View {
        NavigationStack {
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pinned")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.pinnedCommands, id: \.self) { command in
                                    Button {
                                        store.send(.executeQuickCommand(command))
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "pin.fill")
                                            Text(command)
                                                .lineLimit(1)
                                        }
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .frame(minHeight: 44)
                                    .disabled(store.isExecuting)
                                    .contextMenu {
                                        Button {
                                            store.send(.useHistoryCommand(command))
                                            isInputFocused = true
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
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                // Command history
                if store.history.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("ADB Shell")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Execute commands on the Android device")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Quick commands
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                            ForEach(store.suggestions, id: \.self) { cmd in
                                QuickCommandChip(
                                    command: cmd,
                                    isPinned: store.pinnedCommands.contains(cmd),
                                    onRun: {
                                        store.send(.executeQuickCommand(cmd))
                                    },
                                    onTogglePin: {
                                        store.send(.togglePinnedCommand(cmd))
                                    }
                                )
                                .disabled(store.isExecuting)
                            }
                        }
                        .padding(.horizontal)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
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
                }

                Divider()

                // Input bar
                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)

                    TextField("Enter command...", text: $store.commandInput)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isInputFocused)
                        .onSubmit {
                            isInputFocused = false
                            store.send(.executeCommand)
                        }

                    if store.isExecuting {
                        Button {
                            store.send(.cancelExecution)
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Stop command")
                    } else {
                        Button {
                            isInputFocused = false
                            store.send(.executeCommand)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(store.commandInput.isEmpty)
                        .accessibilityLabel("Run command")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Shell")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.send(.onAppear)
            }
            .onDisappear {
                store.send(.cancelExecution)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !store.history.isEmpty {
                        Button {
                            showingClearHistoryConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear shell history")
                    }
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
                Text("This permanently removes all saved command output.")
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
        VStack(alignment: .leading, spacing: 4) {
            // Command line
            HStack(spacing: 4) {
                Text("$")
                    .foregroundColor(.green)
                Text(entry.command)
                    .foregroundColor(.primary)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .font(.system(.subheadline, design: .monospaced))

            // Output
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(entry.isError ? .red : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
            }
        }
        .contextMenu {
            Button(action: onReuse) {
                Label("Reuse Command", systemImage: "arrow.uturn.backward.circle")
            }
            Button(action: onTogglePin) {
                Label(isPinned ? "Unpin Command" : "Pin Command", systemImage: isPinned ? "pin.slash" : "pin")
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
        Button(action: onRun) {
            HStack(spacing: 6) {
                Text(command)
                    .lineLimit(1)
                if isPinned {
                    Image(systemName: "pin.fill")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPinned ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contextMenu {
            Button(action: onTogglePin) {
                Label(isPinned ? "Unpin Command" : "Pin Command", systemImage: isPinned ? "pin.slash" : "pin")
            }
        }
    }
}
