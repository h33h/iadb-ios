import SwiftUI
import ComposableArchitecture
import UIKit

struct ConnectionsFlowView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    var allowsDismissWhenConnected: Bool
    var startsDiscoveryOnAppear = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConnectionView(
                store: store,
                isEmbeddedInNavigationStack: false,
                startsDiscoveryOnAppear: startsDiscoveryOnAppear
            )
            .toolbar {
                if allowsDismissWhenConnected && store.connectionState.isConnected {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("connections.done")
                    }
                }
            }
        }
        .interactiveDismissDisabled(
            !allowsDismissWhenConnected || !store.connectionState.isConnected
        )
    }
}

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    var isEmbeddedInNavigationStack = false
    var startsDiscoveryOnAppear = true

    @Environment(\.openURL) private var openURL
    @FocusState private var focusedField: ManualField?

    private enum ManualField {
        case host
        case port
    }

    var body: some View {
        Group {
            if isEmbeddedInNavigationStack {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
            Section("Current") {
                currentConnectionRow
                if let error = store.lastConnectionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Dismiss Error") { store.send(.clearConnectionError) }
                }
                currentConnectionAction
            }

            Section {
                if let discoveryError = store.discoveryError {
                    Label(discoveryError, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { store.send(.rescan) }
                        .accessibilityIdentifier("connections.refresh")
                } else if store.discoveredDevices.isEmpty {
                    ContentUnavailableView {
                        Label(
                            store.isScanning ? String(localized: "Looking for devices…") : String(localized: "No Nearby Devices"),
                            systemImage: "wifi.slash"
                        )
                    } description: {
                        Text(
                            store.isScanning
                                ? String(localized: "Discovery continues in the background.")
                                : String(localized: "Open Wireless debugging on Android, then refresh nearby devices.")
                        )
                    } actions: {
                        if !store.isScanning {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                store.send(.rescan)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: IADBDesign.controlRadius))
                            .frame(minHeight: IADBDesign.minimumHitTarget)
                            .accessibilityIdentifier("connections.refresh")
                        }
                    }
                } else {
                    ForEach(store.discoveredDevices) { device in
                        DiscoveredDeviceRow(
                            device: device,
                            connectionState: store.connectionState,
                            isCurrentDevice: store.lastConnectionDevice?.id == device.id,
                            onTap: {
                                if device.isPaired {
                                    store.send(.connectToDevice(device))
                                } else {
                                    store.send(.showPairingForDevice(device))
                                }
                            },
                            onRename: pairedDeviceID(for: device).map { pairedID in
                                { store.send(.requestRenamePairedDevice(id: pairedID)) }
                            },
                            onForget: pairedDeviceID(for: device).map { pairedID in
                                { store.send(.requestForgetPairedDevice(id: pairedID)) }
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Nearby")
                    Spacer()
                    if store.isScanning { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Nearby rows arrive incrementally while discovery is active.")
            }

            Section("Saved") {
                if store.offlinePairedDevices.isEmpty {
                    Text("No offline saved devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.offlinePairedDevices) { savedDeviceRow($0) }
                }
            }

            Section {
                Button {
                    store.send(.showManualPairing)
                } label: {
                    Label("Pair Device", systemImage: "link.badge.plus")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }
                .accessibilityIdentifier("connections.pair")

                if store.manualConnection != nil {
                    manualConnectionFields
                }
            } header: {
                Text("Manual")
            } footer: {
                Text("Pairing port creates trust. Connection port starts the regular Wireless debugging session; they are usually different.")
            }

            Section {
                Button(role: .destructive) {
                    store.send(.requestResetADBIdentity)
                } label: {
                    Label("Reset ADB Identity", systemImage: "key.slash")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }
                .accessibilityIdentifier("connections.resetIdentity")
            } header: {
                Text("Security")
            } footer: {
                Text(
                    "Removes the local ADB key and every saved device. Also remove iADB from Android's Wireless debugging paired devices to revoke trust completely."
                )
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(IADBScreenBackground())
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard startsDiscoveryOnAppear else { return }
            store.send(.onAppear)
        }
        .confirmationDialog(
            "Forget \(store.pendingForgetDevice?.displayName ?? String(localized: "this device"))?",
            isPresented: Binding(
                get: { store.pendingForgetDeviceID != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelForgetPairedDevice)
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget on This iPhone", role: .destructive) {
                store.send(.confirmForgetPairedDevice)
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelForgetPairedDevice)
            }
        } message: {
            Text("This disconnects the active session and removes the saved entry. To revoke the key completely, also remove iADB in Android Settings › Wireless debugging › Paired devices.")
        }
        .fullScreenCover(item: $store.scope(state: \.pairing, action: \.pairing)) { pairingStore in
            PairingView(store: pairingStore)
        }
        .sheet(
            isPresented: Binding(
                get: { store.savedDeviceRename != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelRenamePairedDevice)
                    }
                }
            )
        ) {
            SavedDeviceRenameView(store: store)
                .iadbAdaptiveSheetHeight()
        }
        .alert(
            "Reset ADB Identity?",
            isPresented: Binding(
                get: { store.isResetIdentityConfirmationPresented },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelResetADBIdentity)
                    }
                }
            )
        ) {
            Button("Reset Identity", role: .destructive) {
                store.send(.confirmResetADBIdentity)
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelResetADBIdentity)
            }
        } message: {
            Text("This removes the ADB key from Keychain, forgets \(store.pairedDevices.count) saved devices, and disconnects. You will need to pair again.")
        }
    }

    private var currentConnectionRow: some View {
        HStack(spacing: IADBDesign.spacing12) {
            Image(systemName: connectionSymbol)
                .foregroundStyle(connectionTint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.lastConnectionDevice?.name ?? String(localized: "No active device"))
                    .font(.body.weight(.semibold))
                Text(connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let device = store.lastConnectionDevice {
                    Text("Connection port · \(device.host):\(device.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: IADBDesign.spacing8)
            if store.connectionState != .disconnected {
                IADBStatusBadge(title: connectionTitle, kind: connectionBadgeKind)
            }
        }
        .padding(.vertical, IADBDesign.spacing4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var currentConnectionAction: some View {
        if store.connectionState == .connecting {
            Button("Cancel Connection", systemImage: "xmark", role: .cancel) {
                store.send(.cancelConnection)
            }
        } else if store.connectionState.isConnected {
            Button("Disconnect", systemImage: "cable.connector.slash", role: .destructive) {
                store.send(.disconnect)
            }
        } else if store.lastConnectionDevice != nil {
            Button("Reconnect", systemImage: "arrow.clockwise") {
                store.send(.reconnectLastDevice)
            }
        }
    }

    @ViewBuilder
    private var manualConnectionFields: some View {
        if let manual = store.manualConnection {
            Text("Connect \(manual.deviceName)")
                .font(.headline)
            InlineValidatedField("IP address", symbol: "network") {
                TextField("192.168.1.20", text: Binding(
                    get: { store.manualConnection?.hostInput ?? "" },
                    set: { store.send(.manualConnectionHostChanged($0)) }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .host)
            }
            InlineValidatedField("Connection port", symbol: "number", validationMessage: manual.validationError) {
                TextField("37099", text: Binding(
                    get: { store.manualConnection?.portInput ?? "" },
                    set: { store.send(.manualConnectionPortChanged($0)) }
                ))
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .port)
            }
            HStack {
                Button("Cancel") {
                    focusedField = nil
                    store.send(.dismissManualConnection)
                }
                Spacer()
                Button("Connect") {
                    focusedField = nil
                    store.send(.connectManualEndpoint)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.connectionState == .connecting || store.connectionState.isConnected)
            }
        }
    }

    private var connectionStatusCard: some View {
        IADBCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: IADBDesign.spacing) {
                    IADBIconTile(symbol: connectionSymbol, tint: connectionTint)

                    VStack(alignment: .leading, spacing: 5) {
                        IADBStatusBadge(title: connectionTitle, kind: connectionBadgeKind)
                        Text(connectionSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                if let device = store.lastConnectionDevice {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(device.host):\(device.port)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "smartphone")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if store.connectionState == .connecting {
                    Button(role: .cancel) {
                        store.send(.cancelConnection)
                    } label: {
                        Label("Cancel Connection", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .frame(minHeight: 44)
                } else if store.connectionState.isConnected {
                    Button(role: .destructive) {
                        store.send(.disconnect)
                    } label: {
                        Label("Disconnect", systemImage: "cable.connector.slash")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .frame(minHeight: 44)
                    .tint(.red)
                } else if store.lastConnectionDevice != nil {
                    Button {
                        store.send(.reconnectLastDevice)
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func recoveryCard(error: String) -> some View {
        IADBCard {
            VStack(alignment: .leading, spacing: 14) {
                IADBCallout(
                    title: "Connection Needs Attention",
                    message: error,
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )

                VStack(alignment: .leading, spacing: 8) {
                    recoveryStep("Keep both devices on the same Wi-Fi network.", number: 1)
                    recoveryStep("Re-open Wireless debugging if the address changed.", number: 2)
                    recoveryStep("Open “Pair device with pairing code” before pairing again.", number: 3)
                }

                Button("Dismiss Error") {
                    store.send(.clearConnectionError)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minHeight: 44)
            }
        }
    }

    private func recoveryStep(_ title: LocalizedStringResource, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.orange, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(String(localized: title))")
    }

    @ViewBuilder
    private var manualConnectionCard: some View {
        if let manualConnection = store.manualConnection {
            IADBCard {
                VStack(alignment: .leading, spacing: 14) {
                    IADBSectionHeader("Connect \(manualConnection.deviceName)")

                    Text("Enter the regular Wireless debugging address shown on Android. This port is different from the pairing port.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("IP address")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(
                            "192.168.1.20",
                            text: Binding(
                                get: { store.manualConnection?.hostInput ?? "" },
                                set: { store.send(.manualConnectionHostChanged($0)) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .host)
                        .accessibilityLabel("IP address")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wireless debugging port")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(
                            "37099",
                            text: Binding(
                                get: { store.manualConnection?.portInput ?? "" },
                                set: { store.send(.manualConnectionPortChanged($0)) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityLabel("Wireless debugging port")
                    }

                    if let error = manualConnection.validationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)

                        Button("Cancel") {
                            focusedField = nil
                            store.send(.dismissManualConnection)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .frame(minHeight: 44)

                        Button("Connect") {
                            focusedField = nil
                            store.send(.connectManualEndpoint)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                        .disabled(
                            store.connectionState == .connecting
                                || store.connectionState.isConnected
                        )
                    }
                }
            }
        }
    }

    private var firstRunCard: some View {
        IADBCard {
            VStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect Android over Wi-Fi")
                        .font(.title2.weight(.bold))
                    Text("No cable or desktop server required. Pair once, then reconnect from this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    setupStep(
                        symbol: "gearshape.2",
                        title: "Enable Developer Options",
                        detail: "Then turn on Wireless debugging."
                    )
                    setupStep(
                        symbol: "wifi",
                        title: "Use the same Wi-Fi",
                        detail: "Keep iPhone and Android on one local network."
                    )
                    setupStep(
                        symbol: "number",
                        title: "Open the pairing code",
                        detail: "On Android, tap “Pair device with pairing code”."
                    )
                }

                Button {
                    store.send(.showManualPairing)
                } label: {
                    Label("Pair Manually", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .frame(minHeight: 44)
            }
        }
    }

    private var pairActionCard: some View {
        IADBCard {
            VStack(alignment: .leading, spacing: 14) {
                IADBCallout(
                    title: "Add Another Device",
                    message: String(localized: "Open Android's pairing-code dialog, then enter the address and six-digit code."),
                    symbol: "link.badge.plus"
                )
                Button {
                    store.send(.showManualPairing)
                } label: {
                    Label("Pair Manually", systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .frame(minHeight: 44)
            }
        }
    }

    private func setupStep(
        symbol: String,
        title: LocalizedStringResource,
        detail: LocalizedStringResource
    ) -> some View {
        HStack(alignment: .top, spacing: IADBDesign.spacing) {
            IADBIconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var networkDevicesSection: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader(
                "On Your Network",
                subtitle: "Wireless debugging devices discovered nearby"
            ) {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Scanning")
                } else {
                    Button("Rescan") {
                        store.send(.rescan)
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(store.connectionState == .connecting)
                }
            }

            IADBCard {
                if let discoveryError = store.discoveryError {
                    VStack(alignment: .leading, spacing: 14) {
                        IADBCallout(
                            title: "Discovery Unavailable",
                            message: discoveryError,
                            symbol: "wifi.exclamationmark",
                            tint: .orange
                        )
                        HStack(spacing: 10) {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .frame(minHeight: 44)

                            Button("Try Again") {
                                store.send(.rescan)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .frame(minHeight: 44)
                        }
                    }
                } else if store.discoveredDevices.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: store.isScanning ? "dot.radiowaves.left.and.right" : "wifi.slash")
                            .font(.title2)
                            .foregroundStyle(store.isScanning ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        Text(
                            store.isScanning
                                ? String(localized: "Looking for devices…")
                                : String(localized: "No devices found")
                        )
                            .font(.subheadline.weight(.semibold))
                        Text(
                            store.isScanning
                                ? String(localized: "Discovery usually takes a few seconds.")
                                : String(localized: "Open Wireless debugging on Android, then rescan.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.discoveredDevices.enumerated()), id: \.element.id) { index, device in
                            DiscoveredDeviceRow(
                                device: device,
                                connectionState: store.connectionState,
                                isCurrentDevice: store.lastConnectionDevice?.id == device.id,
                                onTap: {
                                    if device.isPaired {
                                        store.send(.connectToDevice(device))
                                    } else {
                                        store.send(.showPairingForDevice(device))
                                    }
                                },
                                onRename: pairedDeviceID(for: device).map { pairedID in
                                    { store.send(.requestRenamePairedDevice(id: pairedID)) }
                                },
                                onForget: pairedDeviceID(for: device).map { pairedID in
                                    { store.send(.requestForgetPairedDevice(id: pairedID)) }
                                }
                            )
                            if index < store.discoveredDevices.count - 1 {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                }
            }
        }
    }

    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader(
                "Saved Devices",
                subtitle: "Enter the current address when discovery is unavailable"
            )

            IADBCard {
                VStack(spacing: 0) {
                    ForEach(Array(store.offlinePairedDevices.enumerated()), id: \.element.id) { index, pairedDevice in
                        savedDeviceRow(pairedDevice)
                        if index < store.offlinePairedDevices.count - 1 {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func savedDeviceRow(_ pairedDevice: PairedDevice) -> some View {
        HStack(spacing: IADBDesign.spacing) {
            Button {
                store.send(.showManualConnection(pairedDevice))
            } label: {
                HStack(spacing: IADBDesign.spacing) {
                    IADBIconTile(symbol: "externaldrive.badge.wifi", tint: .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pairedDevice.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(pairedDevice.lastHost)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Offline · enter current address")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.connectionState == .connecting || store.connectionState.isConnected)

            Menu {
                Button {
                    store.send(.requestRenamePairedDevice(id: pairedDevice.id))
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.send(.requestForgetPairedDevice(id: pairedDevice.id))
                } label: {
                    Label("Forget", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions for \(pairedDevice.displayName)")
        }
        .padding(.vertical, 8)
    }

    private var isFirstRun: Bool {
        store.pairedDevices.isEmpty
            && store.lastConnectionDevice == nil
            && store.discoveredDevices.isEmpty
    }

    private var connectionTitle: String {
        switch store.connectionState {
        case .disconnected: String(localized: "Not Connected")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .error: String(localized: "Connection Failed")
        }
    }

    private var connectionSubtitle: String {
        switch store.connectionState {
        case .disconnected:
            store.lastConnectionDevice == nil
                ? String(localized: "Pair or select a device to start a secure ADB session.")
                : String(localized: "Your last device is ready to reconnect when Wireless debugging is available.")
        case .connecting: String(localized: "Establishing a secure ADB session.")
        case .connected: String(localized: "ADB tools are available across every workspace.")
        case .error: String(localized: "Review the recovery steps below, then try again.")
        }
    }

    private var connectionSymbol: String {
        switch store.connectionState {
        case .disconnected: "wifi.slash"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "checkmark.shield.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var connectionTint: Color {
        switch store.connectionState {
        case .disconnected: .secondary
        case .connecting: .accentColor
        case .connected: .green
        case .error: .orange
        }
    }

    private var connectionBadgeKind: IADBStatusBadge.Kind {
        switch store.connectionState {
        case .disconnected: .neutral
        case .connecting: .progress
        case .connected: .success
        case .error: .error
        }
    }

    private func pairedDeviceID(for device: DiscoveredDevice) -> UUID? {
        ConnectionFeature.State.pairedDevice(
            matching: device,
            in: store.pairedDevices
        )?.id
    }
}

private struct SavedDeviceRenameView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InlineValidatedField(
                        "Device name",
                        symbol: "pencil",
                        validationMessage: store.savedDeviceRename?.validationError
                    ) {
                        TextField(
                            "Android device",
                            text: Binding(
                                get: { store.savedDeviceRename?.nameInput ?? "" },
                                set: { store.send(.savedDeviceRenameChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.words)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit { store.send(.confirmRenamePairedDevice) }
                    }
                } footer: {
                    Text("The saved identity and trust key stay unchanged.")
                }
            }
            .navigationTitle("Rename Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelRenamePairedDevice) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.confirmRenamePairedDevice) }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { isNameFocused = true }
        }
        .presentationDetents([.medium])
    }
}

struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice
    let connectionState: ConnectionState
    let isCurrentDevice: Bool
    let onTap: () -> Void
    var onRename: (() -> Void)? = nil
    var onForget: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: IADBDesign.compactSpacing) {
            Group {
                if connectionState.isConnected && isCurrentDevice {
                    rowContent
                } else {
                    Button(action: onTap) {
                        rowContent
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        connectionState == .connecting
                            || (connectionState.isConnected && !isCurrentDevice)
                    )
                }
            }

            if device.isPaired, onRename != nil || onForget != nil {
                Menu {
                    if let onRename {
                        Button(action: onRename) {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    if let onForget {
                        Button(role: .destructive, action: onForget) {
                            Label("Forget", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(device.name)")
            }
        }
        .padding(.vertical, 8)
        .iadbSelectionHighlight(isSelected: connectionState.isConnected && isCurrentDevice)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(connectionState.isConnected && isCurrentDevice ? .isSelected : [])
    }

    private var rowContent: some View {
        HStack(spacing: IADBDesign.spacing) {
            IADBIconTile(symbol: deviceIcon, tint: statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.body.weight(.medium))
                Text("\(device.host):\(device.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            if !(connectionState.isConnected && isCurrentDevice) {
                Image(systemName: actionIcon)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if connectionState.isConnected && isCurrentDevice { return String(localized: "Connected") }
        if connectionState.isConnected { return String(localized: "Disconnect current device first") }
        if connectionState == .connecting && isCurrentDevice { return String(localized: "Connecting…") }
        if device.isPaired { return String(localized: "Paired · tap to connect") }
        if device.pairingPort != nil { return String(localized: "Ready to pair") }
        return String(localized: "Open pairing-code dialog on Android")
    }

    private var statusColor: Color {
        if connectionState.isConnected && isCurrentDevice { return .green }
        if connectionState == .connecting && isCurrentDevice { return .accentColor }
        if device.isPaired { return .green }
        if device.pairingPort != nil { return .accentColor }
        return .orange
    }

    private var deviceIcon: String {
        if connectionState.isConnected && isCurrentDevice { return "checkmark.circle.fill" }
        if connectionState == .connecting && isCurrentDevice {
            return "antenna.radiowaves.left.and.right"
        }
        return "smartphone"
    }

    private var actionIcon: String {
        if connectionState.isConnected && !isCurrentDevice { return "lock.fill" }
        if device.isPaired { return "arrow.right.circle" }
        return "link.circle"
    }
}
