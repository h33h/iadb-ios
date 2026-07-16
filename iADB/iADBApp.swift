import SwiftUI

/// Temporary bootstrap kept only so the application target remains buildable
/// while the presentation layer is rebuilt from scratch.
@main
struct iADBApp: App {
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
    }
}
