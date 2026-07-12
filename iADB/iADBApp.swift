import SwiftUI
import ComposableArchitecture

@main
struct iADBApp: App {
    let store: StoreOf<AppFeature>

    init() {
        var initialState = AppFeature.State()

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isRecoveryUITesting = arguments.contains("--ui-testing-disconnected-error")
        let isUITesting = arguments.contains("--ui-testing") || isRecoveryUITesting
        let isConnectedUITesting = arguments.contains("--ui-testing-connected")
        let isAppStoreScreenshotMode = arguments.contains("--app-store-screenshots")

        if isAppStoreScreenshotMode {
            initialState = AppStoreDemo.initialState
        }
        if isConnectedUITesting {
            initialState.connection.connectionState = .connected
        }
        if isRecoveryUITesting {
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
        }
        #endif

        store = Store(initialState: initialState) {
            AppFeature()
        } withDependencies: {
            #if DEBUG
            if isAppStoreScreenshotMode {
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
            MainTabView(store: store)
        }
    }
}
