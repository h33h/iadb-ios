import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                if store.connectionState != .disconnected {
                    Section {
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
                    } header: {
                        Text("Status")
                    }
                }

                Section {
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
                            DiscoveredDeviceRow(device: device) {
                                if device.isPaired {
                                    store.send(.connectToDevice(device))
                                } else {
                                    store.send(.showPairingForDevice(device))
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Devices on Network")
                        Spacer()
                        if store.isScanning && !store.discoveredDevices.isEmpty {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }

                Section {
                    Button {
                        store.send(.showManualPairing)
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .foregroundColor(.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading) {
                                Text("Pair New Device")
                                    .font(.body)
                                Text("Enter pairing code manually")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Pair")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How to connect", systemImage: "questionmark.circle")
                            .font(.subheadline.bold())
                        Text("1. Enable Developer Options on your Android device")
                            .font(.caption)
                        Text("2. Enable 'Wireless debugging' in Developer Options")
                            .font(.caption)
                        Text("3. Devices appear here automatically")
                            .font(.caption)
                        Text("4. First time: tap device → enter pairing code")
                            .font(.caption)
                        Text("5. After pairing: tap device → connected!")
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
        case .connecting, .authenticating:
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
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.body)
                    Text("\(device.host):\(device.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if device.isPaired {
                    Text("Paired")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else if device.pairingPort != nil {
                    Text("Ready to pair")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else {
                    Text("Not paired")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .foregroundColor(.primary)
    }
}
