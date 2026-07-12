import SwiftUI
import ComposableArchitecture
import UIKit

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    @Environment(\.openURL) private var openURL
    @State private var showingOpenSourceLicenses = false
    @State private var showingPrivacyPolicy = false

    var body: some View {
        NavigationStack {
            List {
                if store.connectionState != .disconnected
                    || store.lastConnectionError != nil
                    || store.lastConnectionDevice != nil {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                statusIcon
                                Text(store.connectionState.statusText)
                                    .font(.subheadline)
                                Spacer()
                                if store.connectionState == .connecting {
                                    Button("Cancel") {
                                        store.send(.cancelConnection)
                                    }
                                    .foregroundColor(.red)
                                    .font(.subheadline)
                                } else if store.connectionState.isConnected {
                                    Button("Disconnect") {
                                        store.send(.disconnect)
                                    }
                                    .foregroundColor(.red)
                                    .font(.subheadline)
                                }
                            }

                            if let lastDevice = store.lastConnectionDevice,
                               !store.connectionState.isConnected,
                               store.connectionState != .connecting {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Last device")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(lastDevice.name)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(lastDevice.host):\(lastDevice.port)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 12) {
                                        Button("Reconnect") {
                                            store.send(.reconnectLastDevice)
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Button("Rescan") {
                                            store.send(.rescan)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }

                            if let error = store.lastConnectionError {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("How to recover", systemImage: "wrench.and.screwdriver")
                                        .font(.subheadline.bold())
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("1. Make sure iPhone and Android are on the same Wi-Fi.")
                                        .font(.caption)
                                    Text(
                                        "2. Re-open Wireless debugging on Android if the device disappeared "
                                            + "or changed address."
                                    )
                                        .font(.caption)
                                    Text(
                                        "3. If pairing is unavailable, tap 'Pair device with pairing code' "
                                            + "on Android first."
                                    )
                                        .font(.caption)
                                    Button("Dismiss Error") {
                                        store.send(.clearConnectionError)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    } header: {
                        Text("Status")
                    }
                }

                if let manualConnection = store.manualConnection {
                    Section {
                        Text(
                            "Pairing succeeded. Enter the regular Wireless debugging address shown on Android. "
                                + "Its port is different from the pairing port."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "IP address",
                            text: Binding(
                                get: { store.manualConnection?.hostInput ?? "" },
                                set: { store.send(.manualConnectionHostChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                        TextField(
                            "Wireless debugging port",
                            text: Binding(
                                get: { store.manualConnection?.portInput ?? "" },
                                set: { store.send(.manualConnectionPortChanged($0)) }
                            )
                        )
                        .keyboardType(.numberPad)

                        if let error = manualConnection.validationError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Button("Cancel") {
                                store.send(.dismissManualConnection)
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("Connect") {
                                store.send(.connectManualEndpoint)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                store.connectionState == .connecting ||
                                store.connectionState.isConnected
                            )
                        }
                    } header: {
                        Text("Connect \(manualConnection.deviceName)")
                    }
                }

                if !store.offlinePairedDevices.isEmpty {
                    Section {
                        ForEach(store.offlinePairedDevices) { pairedDevice in
                            Button {
                                store.send(.showManualConnection(pairedDevice))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.badge.wifi")
                                        .frame(width: 30)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pairedDevice.displayName)
                                            .foregroundStyle(.primary)
                                        Text(pairedDevice.lastHost)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Offline · tap to enter current address")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(
                                store.connectionState == .connecting ||
                                store.connectionState.isConnected
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.send(.requestForgetPairedDevice(id: pairedDevice.id))
                                } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Saved Devices")
                    } footer: {
                        Text(
                            "A saved device can reconnect even when Bonjour discovery is unavailable. "
                                + "Use the current address from Android's Wireless debugging screen."
                        )
                    }
                }

                Section {
                    Button {
                        store.send(.showManualPairing)
                    } label: {
                        Label("Pair Manually", systemImage: "link.badge.plus")
                    }

                    if let discoveryError = store.discoveryError {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Device discovery unavailable", systemImage: "wifi.exclamationmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            Text(discoveryError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Open Settings") {
                                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                        openURL(settingsURL)
                                    }
                                }
                                .buttonStyle(.bordered)
                                Button("Try Again") {
                                    store.send(.rescan)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    } else if store.discoveredDevices.isEmpty {
                        VStack(spacing: 8) {
                            if store.isScanning {
                                ProgressView()
                                Text("Looking for devices with Wireless Debugging enabled...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("No devices found")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                                Text(
                                    "Open Wireless debugging on Android, or use a saved device above and "
                                        + "enter its current address."
                                )
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
                                }
                            )
                            .disabled(
                                store.connectionState == .connecting ||
                                (store.connectionState.isConnected &&
                                 store.lastConnectionDevice?.id != device.id)
                            )
                            .swipeActions(edge: .trailing) {
                                if device.isPaired, let pairedDeviceID = pairedDeviceID(for: device) {
                                    Button(role: .destructive) {
                                        store.send(.requestForgetPairedDevice(id: pairedDeviceID))
                                    } label: {
                                        Label("Forget", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Devices on Network")
                        Spacer()
                        Button(store.isScanning ? "Scanning..." : "Rescan") {
                            store.send(.rescan)
                        }
                        .font(.caption)
                        .disabled(store.connectionState == .connecting)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How to connect", systemImage: "questionmark.circle")
                            .font(.subheadline.bold())
                        Text("1. Enable Developer Options on your Android device")
                            .font(.caption)
                        Text("2. Enable 'Wireless debugging' in Developer Options")
                            .font(.caption)
                        Text(
                            "3. To pair: tap 'Pair device with pairing code' on Android, then tap the device "
                                + "here and enter the code"
                        )
                            .font(.caption)
                        Text("4. After pairing: tap device → connected")
                            .font(.caption)
                        Text(
                            "5. Swipe left to forget a saved device. To revoke trust completely, also remove "
                                + "iADB from Android's Wireless debugging paired devices."
                        )
                            .font(.caption)
                    }
                    .padding(.vertical, 4)

                    Button {
                        showingPrivacyPolicy = true
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Button {
                        showingOpenSourceLicenses = true
                    } label: {
                        Label("Open Source Licenses", systemImage: "doc.text")
                    }

                    Button(role: .destructive) {
                        store.send(.requestResetADBIdentity)
                    } label: {
                        Label("Reset ADB Identity", systemImage: "key.slash")
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
                        Text(
                            "This removes the ADB key from Keychain, forgets every saved device, and "
                                + "disconnects. You must pair again. Also remove iADB from Android's "
                                + "Wireless debugging paired devices to revoke trust on Android."
                        )
                    }
                } header: {
                    #if DEBUG
                    Text("Help")
                        .onLongPressGesture(minimumDuration: 2) {
                            store.send(.showDebugSettings)
                        }
                    #else
                    Text("Help")
                    #endif
                }
            }
            .navigationTitle("iADB")
            .onAppear { store.send(.onAppear) }
            .confirmationDialog(
                "Forget \(store.pendingForgetDevice?.displayName ?? "this device")?",
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
                Text(
                    "This disconnects the active session and removes the saved entry. To revoke the key "
                        + "completely, also remove iADB in Android Settings › Wireless debugging › Paired devices."
                )
            }
            #if DEBUG
            .sheet(
                isPresented: Binding(
                    get: { store.debugSettingsPresented },
                    set: { isPresented in
                        if isPresented {
                            store.send(.showDebugSettings)
                        } else {
                            store.send(.hideDebugSettings)
                        }
                    }
                )
            ) {
                DebugSettingsSheet(store: store)
            }
            #endif
            .sheet(item: $store.scope(state: \.pairing, action: \.pairing)) { pairingStore in
                PairingView(store: pairingStore)
            }
            .sheet(isPresented: $showingOpenSourceLicenses) {
                OpenSourceLicensesView()
            }
            .sheet(isPresented: $showingPrivacyPolicy) {
                PrivacyPolicyView()
            }
        }
    }

    private func pairedDeviceID(for device: DiscoveredDevice) -> UUID? {
        ConnectionFeature.State.pairedDevice(
            matching: device,
            in: store.pairedDevices
        )?.id
    }
}

#if DEBUG
private struct DebugSettingsSheet: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Use Android Emulator", isOn: $store.debugSettings.useAndroidEmulator)

                    LabeledContent("Host") {
                        TextField("127.0.0.1", text: $store.debugSettings.emulatorHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(debugFieldForegroundStyle)
                    }
                    .disabled(!store.debugSettings.useAndroidEmulator)
                    .foregroundStyle(debugFieldForegroundStyle)
                    .opacity(debugFieldOpacity)

                    LabeledContent("Port") {
                        TextField("5555", text: $store.debugSettings.emulatorPortInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .foregroundStyle(debugFieldForegroundStyle)
                    }
                    .disabled(!store.debugSettings.useAndroidEmulator)
                    .foregroundStyle(debugFieldForegroundStyle)
                    .opacity(debugFieldOpacity)
                } footer: {
                    Text("Uses real ADB after injecting a local emulator into discovery.")
                }
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        store.send(.hideDebugSettings)
                    }
                }
            }
        }
    }

    private var debugFieldForegroundStyle: Color {
        store.debugSettings.useAndroidEmulator ? .primary : .secondary
    }

    private var debugFieldOpacity: Double {
        store.debugSettings.useAndroidEmulator ? 1 : 0.45
    }
}
#endif

extension ConnectionView {
    @ViewBuilder
    private var statusIcon: some View {
        switch store.connectionState {
        case .disconnected:
            Image(systemName: "circle")
                .foregroundColor(.gray)
        case .connecting:
            ProgressView()
                .scaleEffect(0.8)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}

struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice
    let connectionState: ConnectionState
    let isCurrentDevice: Bool
    let onTap: () -> Void

    var body: some View {
        Group {
            if connectionState.isConnected && isCurrentDevice {
                rowContent
                    .accessibilityElement(children: .combine)
            } else {
                Button(action: onTap) {
                    rowContent
                }
            }
        }
        .foregroundColor(.primary)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: deviceIcon)
                .foregroundColor(statusColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.body)
                Text("\(device.host):\(device.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(statusColor)
            }
            Spacer()
            if !(connectionState.isConnected && isCurrentDevice) {
                Image(systemName: actionIcon)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private var statusText: String {
        if connectionState.isConnected && isCurrentDevice {
            return "Connected"
        }
        if connectionState.isConnected {
            return "Disconnect current device first"
        }
        if connectionState == .connecting && isCurrentDevice {
            return "Connecting..."
        }
        if device.isPaired {
            return "Paired - tap to connect"
        }
        if device.pairingPort != nil {
            return "Ready to pair"
        }
        return "Open pairing dialog on Android first"
    }

    private var statusColor: Color {
        if connectionState.isConnected && isCurrentDevice {
            return .green
        }
        if connectionState == .connecting && isCurrentDevice {
            return .blue
        }
        if device.isPaired {
            return .green
        }
        if device.pairingPort != nil {
            return .blue
        }
        return .orange
    }

    private var deviceIcon: String {
        if connectionState.isConnected && isCurrentDevice {
            return "checkmark.circle.fill"
        }
        if connectionState == .connecting && isCurrentDevice {
            return "antenna.radiowaves.left.and.right"
        }
        return "desktopcomputer"
    }

    private var actionIcon: String {
        if connectionState.isConnected && !isCurrentDevice {
            return "lock.fill"
        }
        if device.isPaired {
            return "arrow.right.circle"
        }
        return "link.circle"
    }
}
