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
                DisconnectedOverlay(
                    lastDevice: store.connection.lastConnectionDevice,
                    errorMessage: store.connection.lastConnectionError,
                    onConnect: {
                        store.send(.selectTab(.connection))
                    },
                    onReconnect: store.connection.lastConnectionDevice == nil
                        ? nil
                        : { store.send(.connection(.reconnectLastDevice)) }
                )
            }
        }
    }
}

struct DisconnectedOverlay: View {
    let lastDevice: DiscoveredDevice?
    let errorMessage: String?
    let onConnect: () -> Void
    let onReconnect: (() -> Void)?

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
            if let lastDevice {
                VStack(spacing: 4) {
                    Text(lastDevice.name)
                        .font(.subheadline.weight(.medium))
                    Text("\(lastDevice.host):\(lastDevice.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let onReconnect {
                Button("Reconnect Last Device") {
                    onReconnect()
                }
                .buttonStyle(.borderedProminent)
            }
            if onReconnect == nil {
                Button("Go to Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Go to Connect") {
                    onConnect()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

enum StatusBannerStyle {
    case info
    case success
    case warning
    case error
    case progress

    var iconName: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .progress: return "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .progress: return .accentColor
        }
    }

    var background: Color {
        tint.opacity(0.12)
    }
}

struct StatusBannerView: View {
    let style: StatusBannerStyle
    let message: String
    var showsProgress = false
    var actionTitle: String? = nil
    var onDismiss: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsProgress {
                    ProgressView()
                        .tint(style.tint)
                } else {
                    Image(systemName: style.iconName)
                        .foregroundColor(style.tint)
                }

                Text(message)
                    .font(.caption)
                    .foregroundColor(.primary)

                Spacer(minLength: 0)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
