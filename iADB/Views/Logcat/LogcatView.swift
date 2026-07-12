import SwiftUI
import UIKit
import ComposableArchitecture

struct LogcatView: View {
    @Bindable var store: StoreOf<LogcatFeature>
    @State private var showingExportSheet = false
    @State private var exportText = ""

    var body: some View {
        NavigationStack {
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

                if !store.savedPresets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.savedPresets) { preset in
                                Button {
                                    store.send(.applyPreset(preset))
                                } label: {
                                    Text(preset.name)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.send(.deletePreset(preset.id))
                                    } label: {
                                        Label("Delete Preset", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                }

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
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(store.isRunning ? "Stop log capture" : "Start log capture")

                    // Pause
                    Button {
                        store.send(.togglePause)
                    } label: {
                        Image(systemName: store.isPaused ? "play.circle" : "pause.circle")
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!store.isRunning)
                    .accessibilityLabel(store.isPaused ? "Resume log display" : "Pause log display")

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
                    .frame(minHeight: 44)
                    .accessibilityLabel("Log level: \(store.selectedLevel?.rawValue ?? "All")")

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
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear logs")
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
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Clear log filter")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                HStack(spacing: 8) {
                    TextField("Preset name", text: $store.presetNameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Button("Save Preset") {
                        store.send(.savePreset)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(store.presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Export") {
                        exportText = LogcatFeature.exportString(store.filteredEntries)
                        showingExportSheet = true
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(store.filteredEntries.isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                // Log entries
                if store.filteredEntries.isEmpty && store.isRunning {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                        Text(store.isPaused ? "Log display paused" : "Waiting for log output…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if store.filteredEntries.isEmpty && !store.isRunning {
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
            .onAppear {
                store.send(.onAppear)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $store.autoScroll) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .accessibilityLabel("Auto-scroll logs")
                }
            }
            .sheet(isPresented: $showingExportSheet, onDismiss: {
                exportText = ""
                store.send(.clearExport)
            }) {
                ShareTextSheet(text: exportText, fileName: "logcat.txt")
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
