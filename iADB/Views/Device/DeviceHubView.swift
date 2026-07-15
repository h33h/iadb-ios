import SwiftUI
import ComposableArchitecture

/// The Device workspace is the focused home for connection status, setup,
/// recovery, and an at-a-glance Android hardware summary.
struct DeviceHubView: View {
    let connectionStore: StoreOf<ConnectionFeature>
    let deviceStore: StoreOf<DeviceInfoFeature>
    let screenshotStore: StoreOf<ScreenshotFeature>
    let session: DeviceSessionFeature.State
    let operations: OperationCenterFeature.State

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasStartedDiscovery = false
    @State private var showingConnections = false

    private enum Route: Hashable {
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
                .iadbReadableWidth(maxWidth: 820)
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

                    if connectionStore.connectionState.isConnected {
                        Menu {
                            Button("Disconnect", systemImage: "cable.connector.slash", role: .destructive) {
                                connectionStore.send(.disconnect)
                            }
                        } label: {
                            Image(systemName: "network")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Connection menu")
                    }

                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .deviceDetails:
                    DeviceInfoView(
                        store: deviceStore,
                        isEmbeddedInNavigationStack: false,
                        lastUpdated: snapshotRelationship?.fetchedAt
                    )
                case .settings:
                    SettingsView(
                        store: connectionStore,
                        screenshotStore: screenshotStore,
                        isEmbeddedInNavigationStack: false
                    )
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
        }
        .fullScreenCover(isPresented: $showingConnections) {
            ConnectionsFlowView(
                store: connectionStore,
                allowsDismissWhenConnected: true,
                startsDiscoveryOnAppear: false
            )
        }
        .accessibilityIdentifier("workspace.device")
    }

    private var connectedContent: some View {
        Group {
            connectedHero

            if deviceStore.isLoading {
                StatusBannerView(
                    style: .progress,
                    message: String(localized: "Refreshing device details…"),
                    showsProgress: true
                )
            } else if let error = deviceStore.errorMessage {
                StatusBannerView(
                    style: .error,
                    message: error,
                    actionTitle: String(localized: "Retry"),
                    onDismiss: { deviceStore.send(.dismissError) },
                    onAction: { deviceStore.send(.retryError) }
                )
            }

            deviceMetrics
            connectionActionsCard
            recentActivity
        }
    }

    private var connectedHero: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: IADBDesign.spacing12) {
                    connectedHeroIcon
                    connectedHeroIdentity
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                    connectedHeroIcon
                    connectedHeroIdentity
                }
            }

            Text(snapshotStatus)
                .font(.caption)
                .foregroundStyle(snapshotIsStale ? .orange : .secondary)
                .accessibilityLabel(snapshotAccessibilityLabel)
        }
        .padding(.horizontal, IADBDesign.spacing4)
        .accessibilityElement(children: .contain)
    }

    private var connectedHeroIcon: some View {
        Image(systemName: "smartphone")
            .font(.largeTitle)
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: IADBDesign.controlRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var connectedHeroIdentity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(connectedDeviceTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let endpoint = connectedEndpoint {
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Device address, \(endpoint)")
            }
            IADBStatusBadge(
                title: snapshotIsStale ? String(localized: "Last known") : String(localized: "Connected"),
                kind: snapshotIsStale ? .warning : .success
            )
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
                LabeledMetric(
                    title: "Android",
                    value: deviceStore.details.androidVersion,
                    symbol: "a.square.fill",
                    tint: .green
                )
                LabeledMetric(
                    title: "Battery",
                    value: batteryDisplay,
                    symbol: batteryIcon,
                    tint: batteryTint
                )
                LabeledMetric(
                    title: "Storage",
                    value: storageDisplay,
                    symbol: "internaldrive.fill",
                    tint: .blue
                )
                LabeledMetric(
                    title: "Memory",
                    value: memoryDisplay,
                    symbol: "memorychip.fill",
                    tint: .purple
                )
            }
        }
    }

    private var connectionActionsCard: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("Device")
            IADBCard {
                VStack(spacing: 0) {
                    dashboardNavigationRow(
                        title: "Device Details",
                        subtitle: "Identifiers, system properties and reboot",
                        symbol: "list.bullet.rectangle",
                        route: .deviceDetails,
                        identifier: "device.primary.details"
                    )
                    Divider()
                    Button { showingConnections = true } label: {
                        dashboardRowLabel(
                            title: "Manage Connections",
                            subtitle: "Current, nearby, saved and manual endpoints",
                            symbol: "network"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("device.connections")
                }
            }
        }
    }

    private func dashboardNavigationRow(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        symbol: String,
        route: Route,
        identifier: String
    ) -> some View {
        NavigationLink(value: route) {
            dashboardRowLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func dashboardRowLabel(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        symbol: String
    ) -> some View {
        HStack(spacing: IADBDesign.spacing12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: IADBDesign.spacing8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: IADBDesign.minimumHitTarget)
        .contentShape(Rectangle())
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("Recent Activity")
            IADBCard {
                if operations.operations.isEmpty {
                    Text("Transfers, installs, captures and exports will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: IADBDesign.minimumHitTarget, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(operations.operations.prefix(3).enumerated()), id: \.element.id) { index, operation in
                            DeviceRecentActivityRow(operation: operation)
                            if index < min(operations.operations.count, 3) - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var manageConnectionsButton: some View {
        Button {
            showingConnections = true
        } label: {
            Label("Manage Connections", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: IADBDesign.controlRadius))
        .controlSize(.regular)
        .frame(minHeight: 44)
        .accessibilityIdentifier("device.connections")
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
                    actionTitle: connectionStore.lastConnectionDevice == nil
                        ? nil
                        : String(localized: "Reconnect"),
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
                    Button {
                        showingConnections = true
                    } label: {
                        Label("Connect a Device", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: IADBDesign.controlRadius))
                    .controlSize(.regular)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("device.primary.connect")
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
            Text(
                connectionStore.connectionState == .connecting
                    ? String(localized: "Connecting…")
                    : String(localized: "Connect an Android Device")
            )
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(
                connectionStore.connectionState == .connecting
                    ? String(localized: "Establishing a secure ADB session.")
                    : String(localized: "Pair over local Wi-Fi to use ADB securely from this device.")
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
                Button {
                    showingConnections = true
                } label: {
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

    private func compactStep(number: Int, title: LocalizedStringResource, symbol: String) -> some View {
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
        .accessibilityLabel("Step \(number), \(String(localized: title))")
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
                    Button {
                        showingConnections = true
                    } label: {
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
        return String(localized: "Android Device")
    }

    private var connectedEndpoint: String? {
        guard let device = connectionStore.lastConnectionDevice else { return nil }
        return "\(device.host):\(device.port)"
    }

    private var batteryDisplay: String {
        let level = deviceStore.details.batteryLevel
        let status = deviceStore.details.localizedBatteryStatus
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

    private var storageDisplay: String {
        joinedCapacity(available: deviceStore.details.availableStorage, total: deviceStore.details.totalStorage)
    }

    private var memoryDisplay: String {
        joinedCapacity(available: deviceStore.details.availableMemory, total: deviceStore.details.totalMemory)
    }

    private func joinedCapacity(available: String, total: String) -> String {
        switch (available.isEmpty, total.isEmpty) {
        case (true, true): "—"
        case (false, true): String(localized: "\(available) available")
        case (true, false): total
        case (false, false): String(localized: "\(available) of \(total) free")
        }
    }

    private var snapshotRelationship: RemoteSnapshotRelationship? {
        session.remoteSnapshots[.device]
    }

    private var snapshotIsStale: Bool {
        snapshotRelationship?.isStale == true || !connectionStore.connectionState.isConnected
    }

    private var snapshotStatus: String {
        guard let fetchedAt = snapshotRelationship?.fetchedAt else {
            return String(localized: "Not refreshed yet")
        }
        let relative = fetchedAt.formatted(.relative(presentation: .named))
        return snapshotIsStale
            ? String(localized: "Last updated \(relative) · data may be stale")
            : String(localized: "Updated \(relative)")
    }

    private var snapshotAccessibilityLabel: String {
        snapshotIsStale ? String(localized: "Device data is stale. \(snapshotStatus)") : snapshotStatus
    }

    private var deviceNoun: String {
        connectionStore.offlinePairedDevices.count == 1
            ? String(localized: "Device")
            : String(localized: "Devices")
    }
}

private struct DeviceRecentActivityRow: View {
    let operation: BackgroundOperation

    var body: some View {
        HStack(spacing: IADBDesign.spacing12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.objectName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: IADBDesign.spacing8)
            if let progress = operation.progressFraction, operation.isActive {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: IADBDesign.minimumHitTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(operation.objectName), \(status)")
    }

    private var status: String {
        switch operation.outcome {
        case .success(let summary): summary
        case .failure(let message, _): message
        case .cancelled: String(localized: "Cancelled")
        case nil:
            switch operation.phase {
            case .queued: String(localized: "Queued")
            case .preparing: String(localized: "Preparing")
            case .running: String(localized: "Running")
            case .cleaningUp: String(localized: "Cleaning up")
            case .finished: String(localized: "Finished")
            }
        }
    }

    private var symbol: String {
        switch operation.kind {
        case .upload: "arrow.up.circle"
        case .download: "arrow.down.circle"
        case .installAPK: "shippingbox"
        case .fileMutation: "folder.badge.gearshape"
        case .appMutation: "square.stack.3d.up.badge.xmark"
        case .export: "square.and.arrow.up"
        case .capture: "camera.viewfinder"
        }
    }

    private var tint: Color {
        if case .failure = operation.outcome { return .red }
        if case .success = operation.outcome { return .green }
        return .accentColor
    }
}
