import Foundation
import ComposableArchitecture

@Reducer
struct AppShellFeature {
    enum Root: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
        case device
        case files
        case apps
        case console
        case screens
    }

    enum ConsoleSection: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
        case commandRunner
        case logcat
    }

    enum Destination: Codable, Equatable, Hashable, Sendable {
        case deviceDetails
        case connections
        case settings
        case file(path: String)
        case app(packageName: String)
        case shellCommand(UUID)
        case logEntry(UUID)
        case screenshot(UUID)
    }

    enum ColumnVisibility: String, Codable, Equatable, Sendable {
        case all
        case contentAndDetail
        case detailOnly
    }

    @ObservableState
    struct State: Equatable {
        var selectedRoot: Root = .device
        var consoleSection: ConsoleSection = .commandRunner
        var columnVisibility: ColumnVisibility = .all
        var navigationPaths: [Root: [Destination]] = [:]
        var detailSelections: [Root: Destination] = [:]
        var isDeviceSwitcherPresented = false
        var focusRequestID = 0

        func path(for root: Root) -> [Destination] {
            navigationPaths[root] ?? []
        }

        func detailSelection(for root: Root) -> Destination? {
            detailSelections[root]
        }
    }

    enum Action: Equatable {
        case selectRoot(Root)
        case selectConsoleSection(ConsoleSection)
        case setColumnVisibility(ColumnVisibility)
        case toggleInspectorFocus
        case setPath(root: Root, [Destination])
        case push(root: Root, Destination)
        case popToRoot(Root)
        case selectDetail(root: Root, Destination?)
        case setDeviceSwitcherPresented(Bool)
        case focusSearchOrComposer
        case restore(selectedRoot: Root, consoleSection: ConsoleSection)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .selectRoot(let root):
                state.selectedRoot = root
                return .none

            case .selectConsoleSection(let section):
                state.consoleSection = section
                return .none

            case .setColumnVisibility(let visibility):
                state.columnVisibility = visibility
                return .none

            case .toggleInspectorFocus:
                state.columnVisibility = state.columnVisibility == .detailOnly ? .all : .detailOnly
                return .none

            case .setPath(let root, let path):
                state.navigationPaths[root] = path
                return .none

            case .push(let root, let destination):
                state.navigationPaths[root, default: []].append(destination)
                return .none

            case .popToRoot(let root):
                state.navigationPaths[root] = []
                return .none

            case .selectDetail(let root, let selection):
                state.detailSelections[root] = selection
                return .none

            case .setDeviceSwitcherPresented(let presented):
                state.isDeviceSwitcherPresented = presented
                return .none

            case .focusSearchOrComposer:
                state.focusRequestID &+= 1
                return .none

            case .restore(let root, let section):
                state.selectedRoot = root
                state.consoleSection = section
                return .none
            }
        }
    }
}
