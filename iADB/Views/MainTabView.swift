import SwiftUI
import ComposableArchitecture
import UIKit

/// Five task-oriented roots keep navigation predictable on iPhone and iPad.
struct MainTabView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        TabView(selection: visibleTabBinding) {
            DeviceHubView(
                connectionStore: store.scope(state: \.connection, action: \.connection),
                deviceStore: store.scope(state: \.device, action: \.device)
            )
                .tabItem {
                    Label("Device", systemImage: "smartphone")
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

            ConsoleView(
                shellStore: store.scope(state: \.shell, action: \.shell),
                logcatStore: store.scope(state: \.logcat, action: \.logcat)
            )
                .tabItem {
                    Label("Console", systemImage: "terminal")
                }
                .tag(AppFeature.Tab.console)

            ScreenshotView(store: store.scope(state: \.screenshot, action: \.screenshot))
                .tabItem {
                    Label("Screens", systemImage: "rectangle.stack")
                }
                .tag(AppFeature.Tab.screens)
        }
        .allowsHitTesting(!isShowingDisconnectedOverlay)
        .accessibilityHidden(isShowingDisconnectedOverlay)
        .overlay {
            if isShowingDisconnectedOverlay {
                DisconnectedOverlay(
                    lastDevice: store.connection.lastConnectionDevice,
                    errorMessage: store.connection.lastConnectionError,
                    onOpenDevice: {
                        store.send(.selectTab(.device))
                    },
                    onReconnect: store.connection.lastConnectionDevice == nil
                        ? nil
                        : { store.send(.connection(.reconnectLastDevice)) }
                )
            }
        }
    }

    private var isShowingDisconnectedOverlay: Bool {
        !store.connection.connectionState.isConnected && store.selectedTab.visibleRoot != .device
    }

    private var visibleTabBinding: Binding<AppFeature.Tab> {
        Binding(
            get: { store.selectedTab.visibleRoot },
            set: { store.send(.selectTab($0)) }
        )
    }
}

struct DisconnectedOverlay: View {
    let lastDevice: DiscoveredDevice?
    let errorMessage: String?
    let onOpenDevice: () -> Void
    let onReconnect: (() -> Void)?

    var body: some View {
        ZStack {
            IADBScreenBackground()

            GeometryReader { proxy in
                ScrollView {
                    recoveryCard
                        .frame(maxWidth: 420)
                        .padding(24)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var recoveryCard: some View {
        IADBCard {
            VStack(spacing: IADBDesign.sectionSpacing) {
                IADBIconTile(symbol: "wifi.slash", tint: .orange)

                VStack(spacing: 6) {
                    Text("Device Required")
                        .font(.title3.weight(.semibold))
                    Text("Connect an Android device to use this workspace.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let lastDevice {
                    VStack(spacing: 4) {
                        Text(lastDevice.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(lastDevice.host):\(lastDevice.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(errorMessage)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Connection error. \(errorMessage)")
                }

                VStack(spacing: 10) {
                    if let onReconnect {
                        Button {
                            onReconnect()
                        } label: {
                            Label("Reconnect Last Device", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                    }

                    if onReconnect == nil {
                        Button {
                            onOpenDevice()
                        } label: {
                            Label("Open Device", systemImage: "rectangle.portrait")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                    } else {
                        Button {
                            onOpenDevice()
                        } label: {
                            Label("Open Device", systemImage: "rectangle.portrait")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }
}

enum StatusBannerStyle: Equatable {
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear {
            announceErrorIfNeeded(message)
        }
        .onChange(of: message) { _, newMessage in
            announceErrorIfNeeded(newMessage)
        }
    }

    private func announceErrorIfNeeded(_ message: String) {
        guard style == .error else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
