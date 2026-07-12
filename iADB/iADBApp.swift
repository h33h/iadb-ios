import SwiftUI
import ComposableArchitecture

@main
struct iADBApp: App {
    let store: StoreOf<AppFeature>

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let isConnectedUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing-connected")
        var initialState = AppFeature.State()
        if isConnectedUITesting {
            initialState.connection.connectionState = .connected
        }

        store = Store(initialState: initialState) {
            AppFeature()
        } withDependencies: {
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
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(store: store)
        }
    }
}
