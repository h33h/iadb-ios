import SwiftUI
import ComposableArchitecture

struct ShellView: View {
    @Bindable var store: StoreOf<ShellFeature>
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                                Button {
                                    store.send(.executeQuickCommand(cmd))
                                } label: {
                                    Text(cmd)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.history) { entry in
                                ShellEntryView(entry: entry)
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
                            store.send(.executeCommand)
                        }

                    if store.isExecuting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button {
                            store.send(.executeCommand)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                        }
                        .disabled(store.commandInput.isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !store.history.isEmpty {
                        Button {
                            store.send(.clearHistory)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }
}

struct ShellEntryView: View {
    let entry: ShellHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Command line
            HStack(spacing: 4) {
                Text("$")
                    .foregroundColor(.green)
                Text(entry.command)
                    .foregroundColor(.primary)
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
