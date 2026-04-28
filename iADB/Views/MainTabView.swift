import SwiftUI
import ComposableArchitecture

/// Root tab view — composes all feature stores
struct MainTabView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.selectTab)) {
            ConnectionView(store: store.scope(state: \.connection, action: \.connection))
                .tabItem {
                    Label("Connect", systemImage: "wifi")
                }
                .tag(AppFeature.Tab.connection)

            DeviceInfoView(store: store.scope(state: \.device, action: \.device))
                .tabItem {
                    Label("Device", systemImage: "iphone")
                }
                .tag(AppFeature.Tab.device)

            FileManagerView(store: store.scope(state: \.fileManager, action: \.fileManager))
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(AppFeature.Tab.files)

            AppsView(store: store.scope(state: \.apps, action: \.apps))
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
                .tag(AppFeature.Tab.apps)

            ShellView(store: store.scope(state: \.shell, action: \.shell))
                .tabItem {
                    Label("Shell", systemImage: "terminal")
                }
                .tag(AppFeature.Tab.shell)

            LogcatView(store: store.scope(state: \.logcat, action: \.logcat))
                .tabItem {
                    Label("Logcat", systemImage: "doc.text")
                }
                .tag(AppFeature.Tab.logcat)

            ScreenshotView(store: store.scope(state: \.screenshot, action: \.screenshot))
                .tabItem {
                    Label("Screen", systemImage: "camera")
                }
                .tag(AppFeature.Tab.screenshot)
        }
        .overlay {
            if !store.connection.connectionState.isConnected && store.selectedTab != .connection {
                DisconnectedOverlay {
                    store.send(.selectTab(.connection))
                }
            }
        }
    }
}

struct DisconnectedOverlay: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Not Connected")
                .font(.headline)
            Text("Connect to an Android device first")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Go to Connect") {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
