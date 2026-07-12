import SwiftUI
import ComposableArchitecture

struct ConsoleView: View {
    let shellStore: StoreOf<ShellFeature>
    let logcatStore: StoreOf<LogcatFeature>

    @State private var selectedSection = ConsoleSection.shell

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Console mode", selection: $selectedSection) {
                    ForEach(ConsoleSection.allCases) { section in
                        Text(section.title)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .accessibilityLabel("Console mode")
                .accessibilityValue(selectedSection.title)
                .accessibilityHint("Switches between command shell and device logs")

                Divider()

                switch selectedSection {
                case .shell:
                    ShellView(
                        store: shellStore,
                        isEmbeddedInNavigationStack: true
                    )
                case .logs:
                    LogcatView(
                        store: logcatStore,
                        isEmbeddedInNavigationStack: true
                    )
                }
            }
            .iadbContentWidth()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case shell
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .shell: return "Shell"
        case .logs: return "Logs"
        }
    }
}
