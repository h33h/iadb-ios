import SwiftUI
import ComposableArchitecture

struct ConsoleView: View {
    let shellStore: StoreOf<ShellFeature>
    let logcatStore: StoreOf<LogcatFeature>
    @Bindable var appShellStore: StoreOf<AppShellFeature>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                consolePicker

                Divider()

                switch appShellStore.consoleSection {
                case .commandRunner:
                    ShellView(
                        store: shellStore,
                        isEmbeddedInNavigationStack: true,
                        focusRequestID: appShellStore.focusRequestID
                    )
                case .logcat:
                    LogcatView(
                        store: logcatStore,
                        isEmbeddedInNavigationStack: true,
                        focusRequestID: appShellStore.focusRequestID
                    )
                }
            }
            .iadbWorkspaceWidth()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var consolePicker: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Console mode", selection: consoleSelection) {
                    consolePickerOptions
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Console mode", selection: consoleSelection) {
                    consolePickerOptions
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityLabel("Console mode")
        .accessibilityValue(consoleSectionTitle)
        .accessibilityHint("Switches between command runner and device logs")
    }

    private var consoleSelection: Binding<AppShellFeature.ConsoleSection> {
        Binding(
            get: { appShellStore.consoleSection },
            set: { appShellStore.send(.selectConsoleSection($0)) }
        )
    }

    @ViewBuilder
    private var consolePickerOptions: some View {
        Text("Command Runner").tag(AppShellFeature.ConsoleSection.commandRunner)
        Text("Logcat").tag(AppShellFeature.ConsoleSection.logcat)
    }

    private var consoleSectionTitle: String {
        switch appShellStore.consoleSection {
        case .commandRunner: String(localized: "Command Runner")
        case .logcat: String(localized: "Logcat")
        }
    }
}
