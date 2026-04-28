import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                if store.connectionState != .disconnected || store.lastConnectionError != nil || store.lastConnectionDevice != nil {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                statusIcon
                                Text(store.connectionState.statusText)
                                    .font(.subheadline)
                                Spacer()
                                if store.connectionState.isConnected {
                                    Button("Disconnect") {
                                        store.send(.disconnect)
                                    }
                                    .foregroundColor(.red)
                                    .font(.subheadline)
                                }
                            }

                            if let lastDevice = store.lastConnectionDevice, !store.connectionState.isConnected {
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
                                    Text("2. Re-open Wireless debugging on Android if the device disappeared or changed address.")
                                        .font(.caption)
                                    Text("3. If pairing is unavailable, tap 'Pair device with pairing code' on Android first.")
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

                Section {
                    Button {
                        store.send(.showManualPairing)
                    } label: {
                        Label("Pair Manually", systemImage: "link.badge.plus")
                    }

                    if store.discoveredDevices.isEmpty {
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
                            .swipeActions(edge: .trailing) {
                                if device.isPaired {
                                    Button(role: .destructive) {
                                        store.send(.removePairedDevice(serviceName: device.id))
                                    } label: {
                                        Label("Unpair", systemImage: "trash")
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
                        Text("3. To pair: tap 'Pair device with pairing code' on Android, then tap the device here and enter the code")
                            .font(.caption)
                        Text("4. After pairing: tap device → connected")
                            .font(.caption)
                        Text("5. Swipe left on a paired device to unpair")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Help")
                }
            }
            .navigationTitle("iADB")
            .onAppear { store.send(.onAppear) }
            .sheet(item: $store.scope(state: \.pairing, action: \.pairing)) { pairingStore in
                PairingView(store: pairingStore)
            }
        }
    }

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
        Button(action: onTap) {
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
                Image(systemName: actionIcon)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .foregroundColor(.primary)
    }

    private var statusText: String {
        if connectionState.isConnected && isCurrentDevice {
            return "Connected"
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
        if device.isPaired {
            return "arrow.right.circle"
        }
        return "link.circle"
    }
}
