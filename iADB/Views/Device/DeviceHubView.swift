import SwiftUI
import ComposableArchitecture

/// The Device workspace is the focused home for connection status, setup,
/// recovery, and an at-a-glance Android hardware summary.
struct DeviceHubView: View {
    let connectionStore: StoreOf<ConnectionFeature>
    let deviceStore: StoreOf<DeviceInfoFeature>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasStartedDiscovery = false

    private enum Route: Hashable {
        case connections
        case deviceDetails
        case settings
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                    if connectionStore.connectionState.isConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                }
                .padding(IADBDesign.contentPadding)
                .padding(.bottom, 24)
                .iadbContentWidth()
            }
            .background(IADBScreenBackground())
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if connectionStore.connectionState.isConnected {
                        Button {
                            deviceStore.send(.fetchDeviceInfo)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(deviceStore.isLoading || deviceStore.isRebooting)
                        .accessibilityLabel("Refresh device info")
                    }

                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .connections:
                    ConnectionView(
                        store: connectionStore,
                        isEmbeddedInNavigationStack: false,
                        startsDiscoveryOnAppear: false
                    )
                case .deviceDetails:
                    DeviceInfoView(store: deviceStore, isEmbeddedInNavigationStack: false)
                case .settings:
                    SettingsView(store: connectionStore, isEmbeddedInNavigationStack: false)
                }
            }
            .onAppear {
                if !hasStartedDiscovery {
                    hasStartedDiscovery = true
                    connectionStore.send(.onAppear)
                }
                refreshDetailsIfNeeded()
            }
            .onChange(of: connectionStore.connectionState.isConnected) { _, isConnected in
                guard isConnected else { return }
                refreshDetailsIfNeeded()
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: connectionStore.connectionState)
        }
    }

    private var connectedContent: some View {
        Group {
            connectedHero

            if deviceStore.isLoading {
                StatusBannerView(
                    style: .progress,
                    message: "Refreshing device details…",
                    showsProgress: true
                )
            } else if let error = deviceStore.errorMessage {
                StatusBannerView(
                    style: .error,
                    message: error,
                    actionTitle: "Retry",
                    onDismiss: { deviceStore.send(.dismissError) },
                    onAction: { deviceStore.send(.retryError) }
                )
            }

            deviceMetrics
            connectionActionsCard
        }
    }

    private var connectedHero: some View {
        IADBCard {
            VStack(alignment: .leading, spacing: 16) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        connectedHeroIcon
                        connectedHeroIdentity
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        connectedHeroIcon
                        connectedHeroIdentity
                        Spacer(minLength: 0)
                    }
                }

                Text("Ready for wireless ADB commands, transfers, and captures.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink(value: Route.deviceDetails) {
                    Label("View Device Details", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var connectedHeroIcon: some View {
        Image(systemName: "smartphone")
            .font(.largeTitle)
            .foregroundStyle(Color.accentColor)
            .frame(width: 64, height: 64)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var connectedHeroIdentity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(connectedDeviceTitle)
                .font(.title2.weight(.bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let endpoint = connectedEndpoint {
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            IADBStatusBadge(title: "ADB Connected", kind: .success)
        }
    }

    private var deviceMetrics: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("At a Glance")
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 145),
                        spacing: IADBDesign.spacing
                    )
                ],
                spacing: IADBDesign.spacing
            ) {
                IADBMetricCard(
                    title: "Android",
                    value: deviceStore.details.androidVersion,
                    symbol: "a.square.fill",
                    tint: .green
                )
                IADBMetricCard(
                    title: "Battery",
                    value: batteryDisplay,
                    symbol: batteryIcon,
                    tint: batteryTint
                )
                IADBMetricCard(
                    title: "Available RAM",
                    value: deviceStore.details.availableMemory,
                    symbol: "memorychip.fill",
                    tint: .purple
                )
                IADBMetricCard(
                    title: "IP Address",
                    value: deviceStore.details.ipAddress,
                    symbol: "network",
                    tint: .blue
                )
            }
        }
    }

    private var connectionActionsCard: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("Connection")
            IADBCard {
                VStack(alignment: .leading, spacing: 14) {
                    IADBCallout(
                        title: "Wireless ADB",
                        message: "Manage paired devices or end the current secure session.",
                        symbol: "antenna.radiowaves.left.and.right"
                    )

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            manageConnectionsButton
                            disconnectButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            manageConnectionsButton
                            disconnectButton
                        }
                    }
                }
            }
        }
    }

    private var manageConnectionsButton: some View {
        NavigationLink(value: Route.connections) {
            Label("Manage Connections", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(minHeight: 44)
    }

    private var disconnectButton: some View {
        Button(role: .destructive) {
            connectionStore.send(.disconnect)
        } label: {
            Label("Disconnect", systemImage: "cable.connector.slash")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(.red)
        .frame(minHeight: 44)
    }

    private var disconnectedContent: some View {
        Group {
            disconnectedHero

            if let error = connectionStore.lastConnectionError {
                StatusBannerView(
                    style: .error,
                    message: error,
                    actionTitle: connectionStore.lastConnectionDevice == nil ? nil : "Reconnect",
                    onDismiss: { connectionStore.send(.clearConnectionError) },
                    onAction: connectionStore.lastConnectionDevice == nil ? nil : {
                        if connectionStore.lastConnectionDevice != nil {
                            connectionStore.send(.reconnectLastDevice)
                        }
                    }
                )
            }

            if !connectionStore.discoveredDevices.isEmpty {
                nearbyDevicesCard
            } else {
                gettingStartedCard
            }

            if !connectionStore.offlinePairedDevices.isEmpty {
                savedDeviceSummaryCard
            }
        }
    }

    private var disconnectedHero: some View {
        IADBCard {
            VStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        disconnectedHeroIcon
                        disconnectedHeroMessage
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        disconnectedHeroIcon
                        disconnectedHeroMessage
                    }
                }

                if let lastDevice = connectionStore.lastConnectionDevice,
                   connectionStore.connectionState != .connecting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lastDevice.name)
                            .font(.body.weight(.semibold))
                        Text("\(lastDevice.host):\(lastDevice.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            reconnectButton
                            manageConnectionsButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            reconnectButton
                            manageConnectionsButton
                        }
                    }
                } else if connectionStore.connectionState == .connecting {
                    cancelConnectionButton
                } else {
                    NavigationLink(value: Route.connections) {
                        Label("Connect a Device", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var disconnectedHeroIcon: some View {
        IADBIconTile(
            symbol: connectionStore.connectionState == .connecting
                ? "antenna.radiowaves.left.and.right"
                : "cable.connector.horizontal",
            tint: connectionStore.connectionState == .connecting ? .accentColor : .orange
        )
    }

    private var disconnectedHeroMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(connectionStore.connectionState == .connecting ? "Connecting…" : "Connect an Android Device")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(
                connectionStore.connectionState == .connecting
                    ? "Establishing a secure ADB session."
                    : "Pair over local Wi-Fi to use ADB securely from this device."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reconnectButton: some View {
        Button {
            connectionStore.send(.reconnectLastDevice)
        } label: {
            Label("Reconnect", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(minHeight: 44)
    }

    private var cancelConnectionButton: some View {
        Button(role: .cancel) {
            connectionStore.send(.cancelConnection)
        } label: {
            Label("Cancel Connection", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(minHeight: 44, alignment: .leading)
    }

    private var nearbyDevicesCard: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader(
                "Ready Nearby",
                subtitle: "Tap a paired device to connect or an unpaired device to pair"
            ) {
                if connectionStore.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            IADBCard {
                VStack(spacing: 0) {
                    ForEach(
                        Array(connectionStore.discoveredDevices.prefix(3).enumerated()),
                        id: \.element.id
                    ) { index, device in
                        DiscoveredDeviceRow(
                            device: device,
                            connectionState: connectionStore.connectionState,
                            isCurrentDevice: connectionStore.lastConnectionDevice?.id == device.id,
                            onTap: {
                                if device.isPaired {
                                    connectionStore.send(.connectToDevice(device))
                                } else {
                                    connectionStore.send(.showPairingForDevice(device))
                                }
                            },
                            onForget: nil
                        )
                        if index < min(connectionStore.discoveredDevices.count, 3) - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }

            if connectionStore.discoveredDevices.count > 3 {
                NavigationLink(value: Route.connections) {
                    Text("View All Devices")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("Three Steps to Connect")
            IADBCard {
                VStack(alignment: .leading, spacing: 16) {
                    compactStep(number: 1, title: "Enable Wireless debugging", symbol: "gearshape.2")
                    compactStep(number: 2, title: "Open “Pair device with pairing code”", symbol: "number")
                    compactStep(number: 3, title: "Enter the address and code in iADB", symbol: "link")
                }
            }
        }
    }

    private func compactStep(number: Int, title: String, symbol: String) -> some View {
        HStack(spacing: IADBDesign.spacing) {
            ZStack {
                IADBIconTile(symbol: symbol)
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 17, y: -17)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title)")
    }

    private var savedDeviceSummaryCard: some View {
        IADBCard {
            HStack(alignment: .top, spacing: IADBDesign.spacing) {
                IADBIconTile(symbol: "externaldrive.badge.wifi", tint: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(connectionStore.offlinePairedDevices.count) Saved \(deviceNoun)")
                        .font(.headline)
                    Text("Saved devices are offline or need their current Wireless debugging address.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink(value: Route.connections) {
                        Text("Manage Saved Devices")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private func refreshDetailsIfNeeded() {
        guard connectionStore.connectionState.isConnected,
              deviceStore.details.snapshotText.isEmpty,
              !deviceStore.isLoading else { return }
        deviceStore.send(.fetchDeviceInfo)
    }

    private var connectedDeviceTitle: String {
        if !deviceStore.details.model.isEmpty { return deviceStore.details.model }
        if let name = connectionStore.lastConnectionDevice?.name, !name.isEmpty { return name }
        return "Android Device"
    }

    private var connectedEndpoint: String? {
        guard let device = connectionStore.lastConnectionDevice else { return nil }
        return "\(device.host):\(device.port)"
    }

    private var batteryDisplay: String {
        let level = deviceStore.details.batteryLevel
        let status = deviceStore.details.batteryStatus
        return switch (level.isEmpty, status.isEmpty) {
        case (true, true): ""
        case (false, true): level
        case (true, false): status
        case (false, false): "\(level) · \(status)"
        }
    }

    private var batteryIcon: String {
        switch deviceStore.details.batteryStatus {
        case "Charging": "battery.100.bolt"
        case "Full": "battery.100"
        default: "battery.75percent"
        }
    }

    private var batteryTint: Color {
        switch deviceStore.details.batteryStatus {
        case "Charging", "Full": .green
        default: .orange
        }
    }

    private var deviceNoun: String {
        connectionStore.offlinePairedDevices.count == 1 ? "Device" : "Devices"
    }
}
