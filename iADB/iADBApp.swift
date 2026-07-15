import SwiftUI
import ComposableArchitecture
import UIKit

@main
struct iADBApp: App {
    let store: StoreOf<AppFeature>

    init() {
        var initialState = AppFeature.State()

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-disable-animations") {
            UIView.setAnimationsEnabled(false)
        }
        let isRecoveryUITesting = arguments.contains("--ui-testing-disconnected-error")
        let isUITesting = arguments.contains("--ui-testing") || isRecoveryUITesting
        let isConnectedUITesting = arguments.contains("--ui-testing-connected")
        let fixture = AppStoreDemo.fixture(from: arguments)

        if let fixture {
            initialState = AppStoreDemo.state(for: fixture)
        }
        if let root = AppStoreDemo.root(from: arguments) {
            initialState.selectedTab = root
        }
        if isConnectedUITesting {
            initialState.hasEnteredWorkspace = true
            initialState.connection.connectionState = .connected
            let identity = DeviceIdentity(
                stableID: "service:ui-preview-device",
                displayName: "Preview Android",
                adbFingerprint: nil
            )
            let endpoint = Endpoint(host: "192.0.2.20", port: 37141)
            initialState.session.selectedDevice = identity
            initialState.session.transport = .connected(endpoint: endpoint, since: Date())
            initialState.session.lastKnownEndpoint = endpoint
            initialState.session.lastSuccessfulContact = Date()
            initialState.session.capabilities = .connected
        }
        if isRecoveryUITesting {
            initialState.hasEnteredWorkspace = true
            let device = DiscoveredDevice(
                id: "ui-recovery-device",
                name: "Saved Android Device",
                host: "192.0.2.42",
                port: 37141,
                isPaired: true
            )
            let message = "The saved device could not be reached after the Wi-Fi network changed. "
                + "Reconnect when Wireless debugging is available, or open Device to choose another connection."
            initialState.connection.lastConnectionDevice = device
            initialState.connection.lastConnectionError = message
            initialState.connection.connectionState = .error(message)
            let identity = DeviceIdentity.resolved(from: device, pairedDevices: [])
            initialState.session.selectedDevice = identity
            initialState.session.lastKnownEndpoint = Endpoint(host: device.host, port: device.port)
            initialState.session.transport = .disconnected(
                reason: .connectionFailed(message),
                lastSeen: Date().addingTimeInterval(-120)
            )
            initialState.session.capabilities = .offline
        }
        #endif

        store = Store(initialState: initialState) {
            AppFeature()
        } withDependencies: {
            #if DEBUG
            if fixture != nil {
                $0.adbClient = .previewValue
                $0.deviceDiscoveryClient = DeviceDiscoveryClient(
                    start: { _ in
                        AsyncStream { continuation in
                            continuation.yield(.ready)
                            continuation.yield(.devices([AppStoreDemo.device]))
                            continuation.finish()
                        }
                    },
                    stop: {}
                )
                $0.pairedDevicesClient = PairedDevicesClient(
                    load: { [AppStoreDemo.pairedDevice] },
                    save: { _ in }
                )
                $0.shellPersistenceClient = .previewValue
                $0.logcatPersistenceClient = .previewValue
                $0.screenshotPersistenceClient = .previewValue
                return
            }

            guard isUITesting || isConnectedUITesting else { return }
            $0.deviceDiscoveryClient = DeviceDiscoveryClient(
                start: { _ in
                    AsyncStream { continuation in
                        continuation.yield(.ready)
                        continuation.yield(.devices([]))
                        continuation.finish()
                    }
                },
                stop: {}
            )
            $0.pairedDevicesClient = PairedDevicesClient(load: { [] }, save: { _ in })
            if isConnectedUITesting {
                $0.adbClient = .previewValue
            }
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            AdaptiveAppShell(store: store)
        }
        .commands {
            CommandMenu("Workspaces") {
                Button("Device") { store.send(.appShell(.selectRoot(.device))) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Files") { store.send(.appShell(.selectRoot(.files))) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Apps") { store.send(.appShell(.selectRoot(.apps))) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Console") { store.send(.appShell(.selectRoot(.console))) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Screens") { store.send(.appShell(.selectRoot(.screens))) }
                    .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Command Runner") {
                    store.send(.appShell(.selectRoot(.console)))
                    store.send(.appShell(.selectConsoleSection(.commandRunner)))
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Logcat") {
                    store.send(.appShell(.selectRoot(.console)))
                    store.send(.appShell(.selectConsoleSection(.logcat)))
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Refresh") { store.send(.refreshSelectedRoot) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Focus Search or Command") {
                    store.send(.appShell(.focusSearchOrComposer))
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Activity Center") { store.send(.operations(.setPresented(true))) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Focus Inspector") { store.send(.appShell(.toggleInspectorFocus)) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Delete Selected Screenshots") {
                    store.send(.screenshot(.requestBulkDelete))
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(
                    store.appShell.selectedRoot != .screens ||
                    store.screenshot.selectedScreenshotIDs.isEmpty
                )
            }
        }
    }
}
