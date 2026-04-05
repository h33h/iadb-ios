import SwiftUI
import ComposableArchitecture

struct LogcatView: View {
    @Bindable var store: StoreOf<LogcatFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Controls bar
                HStack(spacing: 12) {
                    // Start/Stop
                    Button {
                        if store.isRunning {
                            store.send(.stopLogcat)
                        } else {
                            store.send(.startLogcat)
                        }
                    } label: {
                        Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                            .foregroundColor(store.isRunning ? .red : .green)
                    }

                    // Pause
                    Button {
                        store.send(.togglePause)
                    } label: {
                        Image(systemName: store.isPaused ? "play.circle" : "pause.circle")
                    }
                    .disabled(!store.isRunning)

                    Divider().frame(height: 20)

                    // Level filter
                    Menu {
                        Button("All Levels") { store.send(.binding(.set(\.selectedLevel, nil))) }
                        Divider()
                        ForEach([LogEntry.LogLevel.verbose, .debug, .info, .warning, .error, .fatal], id: \.rawValue) { level in
                            Button(level.rawValue + " - " + levelName(level)) {
                                store.send(.binding(.set(\.selectedLevel, level)))
                            }
                        }
                    } label: {
                        Text(store.selectedLevel?.rawValue ?? "All")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)
                    }

                    Spacer()

                    // Entry count
                    Text("\(store.filteredEntries.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Clear
                    Button {
                        store.send(.clearLog)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter by tag or message", text: $store.filterText)
                        .font(.caption)
                        .autocapitalization(.none)
                    if !store.filterText.isEmpty {
                        Button {
                            store.send(.binding(.set(\.filterText, "")))
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                Divider()

                // Log entries
                if store.filteredEntries.isEmpty && !store.isRunning {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Logs")
                            .font(.headline)
                        Text("Tap play to start capturing logcat output")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(store.filteredEntries) { entry in
                                    LogEntryRow(entry: entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .onChange(of: store.filteredEntries.count) { _, _ in
                            if store.autoScroll, let last = store.filteredEntries.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Logcat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $store.autoScroll) {
                        Image(systemName: "arrow.down.to.line")
                    }
                }
            }
        }
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
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(entry.level.rawValue)
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundColor(levelColor)
                .frame(width: 14)

            Text(entry.tag)
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundColor(.accentColor)
                .lineLimit(1)
                .frame(maxWidth: 100, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button {
                UIPasteboard.general.string = "\(entry.level.rawValue)/\(entry.tag): \(entry.message)"
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .verbose: return .gray
        case .debug: return .blue
        case .info: return .green
        case .warning: return .orange
        case .error, .fatal: return .red
        case .silent, .unknown: return .primary
        }
    }
}
