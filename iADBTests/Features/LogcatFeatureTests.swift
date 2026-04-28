import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct LogcatFeatureTests {
    @Test
    func stopLogcat() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true)
        ) {
            LogcatFeature()
        }

        await store.send(.stopLogcat) {
            $0.isRunning = false
        }
    }

    @Test
    func logcatLinesAppended() async {
        let store = TestStore(initialState: LogcatFeature.State(isRunning: true)) {
            LogcatFeature()
        }

        let lines = [
            "01-01 00:00:00.000  1000  1001 I ActivityManager: Start proc",
            "01-01 00:00:00.001  1000  1002 D WindowManager: Relayout"
        ]

        // LogEntry generates UUID on init, can't match exactly
        store.exhaustivity = .off
        await store.send(.logcatLines(lines))
        store.exhaustivity = .on

        #expect(store.state.entries.count == 2)
        #expect(store.state.entries[0].tag == "ActivityManager")
        #expect(store.state.entries[1].tag == "WindowManager")
    }

    @Test
    func logcatLinesPausedBuffered() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true, isPaused: true)
        ) {
            LogcatFeature()
        }

        let line = "01-01 00:00:00.000  1000  1001 I Test: msg"
        await store.send(.logcatLines([line])) {
            $0.pauseBuffer = [line]
        }
        #expect(store.state.entries.isEmpty)
    }

    @Test
    func togglePauseAppliesBuffer() async {
        let line = "01-01 00:00:00.000  1000  1001 I Test: buffered"
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true, isPaused: true, pauseBuffer: [line])
        ) {
            LogcatFeature()
        }

        store.exhaustivity = .off
        await store.send(.togglePause) {
            $0.isPaused = false
            $0.pauseBuffer = []
        }
        store.exhaustivity = .on

        #expect(store.state.entries.count == 1)
        #expect(store.state.entries[0].tag == "Test")
    }

    @Test
    func maxEntriesLimit() async {
        let entries = (0..<100).map { _ in
            LogEntry(
                timestamp: "00:00:00",
                pid: "1000",
                tid: "1001",
                level: .info,
                tag: "Tag",
                message: "msg"
            )
        }
        let store = TestStore(
            initialState: LogcatFeature.State(entries: entries, isRunning: true, maxEntries: 110)
        ) {
            LogcatFeature()
        }

        let newLines = (100..<120).map { i in
            "01-01 00:00:00.000  1000  1001 I Tag: msg \(i)"
        }

        store.exhaustivity = .off
        await store.send(.logcatLines(newLines))
        store.exhaustivity = .on

        // 100 + 20 = 120, trimmed to maxEntries=110
        #expect(store.state.entries.count == 110)
    }

    @Test
    func clearLog() async {
        let entry = LogEntry(
            timestamp: "00:00:00",
            pid: "1",
            tid: "1",
            level: .info,
            tag: "Test",
            message: "msg"
        )
        let store = TestStore(
            initialState: LogcatFeature.State(entries: [entry])
        ) {
            LogcatFeature()
        }

        await store.send(.clearLog) {
            $0.entries = []
        }
    }

    @Test
    func togglePause() async {
        let store = TestStore(initialState: LogcatFeature.State()) {
            LogcatFeature()
        }

        await store.send(.togglePause) {
            $0.isPaused = true
        }
    }

    @Test
    func filteredEntries() {
        let entries = [
            LogEntry(timestamp: "00:00:00", pid: "1", tid: "1", level: .info, tag: "ActivityManager", message: "Start proc"),
            LogEntry(timestamp: "00:00:01", pid: "1", tid: "1", level: .debug, tag: "WindowManager", message: "Relayout"),
            LogEntry(timestamp: "00:00:02", pid: "1", tid: "1", level: .error, tag: "System", message: "Error occurred"),
        ]

        // Filter by level
        var state = LogcatFeature.State(entries: entries, selectedLevel: .error)
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "System")

        // Filter by text
        state = LogcatFeature.State(entries: entries, filterText: "Window")
        #expect(state.filteredEntries.count == 1)
        #expect(state.filteredEntries[0].tag == "WindowManager")

        // Both filters
        state = LogcatFeature.State(entries: entries, filterText: "Error", selectedLevel: .error)
        #expect(state.filteredEntries.count == 1)
    }

    @Test
    func logcatStopped() async {
        let store = TestStore(
            initialState: LogcatFeature.State(isRunning: true)
        ) {
            LogcatFeature()
        }

        await store.send(.logcatStopped) {
            $0.isRunning = false
        }
    }
}
