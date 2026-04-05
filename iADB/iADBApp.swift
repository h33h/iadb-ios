import SwiftUI
import ComposableArchitecture

@main
struct iADBApp: App {
    let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(store: store)
        }
    }
}
