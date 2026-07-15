import ComposableArchitecture
import Testing
@testable import iADB

@MainActor
struct AppShellFeatureTests {
    @Test
    func focusCommandCreatesDistinctRequests() async {
        let store = TestStore(initialState: AppShellFeature.State()) {
            AppShellFeature()
        }

        await store.send(.focusSearchOrComposer) {
            $0.focusRequestID = 1
        }
        await store.send(.focusSearchOrComposer) {
            $0.focusRequestID = 2
        }
    }

    @Test
    func rootPathsAndDetailsSurviveRootSwitches() async {
        let file = AppShellFeature.Destination.file(path: "/sdcard/Download/report.txt")
        let app = AppShellFeature.Destination.app(packageName: "com.example.notes")
        let store = TestStore(initialState: AppShellFeature.State()) {
            AppShellFeature()
        }

        await store.send(.push(root: .files, file)) {
            $0.navigationPaths[.files] = [file]
        }
        await store.send(.selectDetail(root: .files, file)) {
            $0.detailSelections[.files] = file
        }
        await store.send(.selectRoot(.apps)) {
            $0.selectedRoot = .apps
        }
        await store.send(.push(root: .apps, app)) {
            $0.navigationPaths[.apps] = [app]
        }
        await store.send(.selectRoot(.files)) {
            $0.selectedRoot = .files
        }

        #expect(store.state.path(for: .files) == [file])
        #expect(store.state.detailSelection(for: .files) == file)
        #expect(store.state.path(for: .apps) == [app])
    }

    @Test
    func restoreKeepsConsoleSubsectionAndColumnPreference() async {
        let store = TestStore(initialState: AppShellFeature.State()) {
            AppShellFeature()
        }

        await store.send(.setColumnVisibility(.contentAndDetail)) {
            $0.columnVisibility = .contentAndDetail
        }
        await store.send(.restore(selectedRoot: .console, consoleSection: .logcat)) {
            $0.selectedRoot = .console
            $0.consoleSection = .logcat
        }
        #expect(store.state.columnVisibility == .contentAndDetail)
    }

    @Test
    func inspectorFocusShortcutRoundTripsWithoutLosingSelection() async {
        let selection = AppShellFeature.Destination.app(packageName: "com.example.app")
        let store = TestStore(initialState: AppShellFeature.State(
            selectedRoot: .apps,
            detailSelections: [.apps: selection]
        )) {
            AppShellFeature()
        }

        await store.send(.toggleInspectorFocus) { $0.columnVisibility = .detailOnly }
        await store.send(.toggleInspectorFocus) { $0.columnVisibility = .all }
        #expect(store.state.detailSelection(for: .apps) == selection)
    }

    @Test
    func stageManagerCompactWidthKeepsAdaptiveSplitUntilAccessibilityText() {
        #expect(AdaptiveAppShell.shouldUseSplitLayout(
            isPad: true,
            isHorizontalRegular: false,
            isAccessibilityText: false
        ))
        #expect(!AdaptiveAppShell.shouldUseSplitLayout(
            isPad: true,
            isHorizontalRegular: false,
            isAccessibilityText: true
        ))
        #expect(!AdaptiveAppShell.shouldUseSplitLayout(
            isPad: false,
            isHorizontalRegular: false,
            isAccessibilityText: false
        ))
        #expect(!AdaptiveAppShell.shouldUseSplitLayout(
            isPad: false,
            isHorizontalRegular: true,
            isAccessibilityText: false
        ))
    }
}
