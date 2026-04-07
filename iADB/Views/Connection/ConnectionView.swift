import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                // Quick Connect Section
                Section {
                    HStack(spacing: 12) {
                        VStack(spacing: 8) {
                            TextField("IP Address (e.g. 192.168.1.100)", text: $store.hostInput)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            HStack {
                                TextField("Port", text: $store.portInput)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)

                                Spacer()

                                Button {
                                    store.send(.quickConnect)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link")
                                        Text("Connect")
                                    }
                                    .font(.subheadline.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.hostInput.isEmpty || store.connectionState == .connecting)
                            }
                        }
                    }
                } header: {
                    Text("Quick Connect")
                }

                // Connection Status
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
                        if case .authenticating = store.connectionState {
                            Text("Please check the Android device screen and allow USB debugging connection.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Status")
                    }
                }

                // Saved Devices
                Section {
                    if store.savedDevices.isEmpty {
                        Text("No saved devices")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(store.savedDevices) { device in
                            SavedDeviceRow(device: device) {
                                store.send(.connectToDevice(device))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.send(.removeDevice(device))
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved Devices")
                        Spacer()
                        Button {
                            store.send(.toggleAddDevice)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                }

                // Pairing Section (Android 11+)
                Section {
                    Button {
                        store.send(.showPairing)
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .foregroundColor(.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading) {
                                Text("Pair with Pairing Code")
                                    .font(.body)
                                Text("Enter 6-digit code from device")
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
                    Text("Pair New Device (Android 11+)")
                }

                // Help Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How to enable WiFi ADB", systemImage: "questionmark.circle")
                            .font(.subheadline.bold())
                        Text("1. Enable Developer Options on your Android device")
                            .font(.caption)
                        Text("2. Enable 'Wireless debugging' in Developer Options")
                            .font(.caption)
                        Text("3. Tap 'Pair device with pairing code' and use Pair above")
                            .font(.caption)
                        Text("4. Then connect using the IP and port shown on the main Wireless debugging screen")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Help")
                }
            }
            .navigationTitle("iADB")
            .onAppear { store.send(.onAppear) }
            .sheet(isPresented: $store.showingAddDevice) {
                AddDeviceSheet(store: store)
            }
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

struct SavedDeviceRow: View {
    let device: SavedDevice
    let onConnect: () -> Void

    private var isPaired: Bool { device.port == 0 }

    var body: some View {
        Button(action: onConnect) {
            HStack {
                Image(systemName: isPaired ? "wifi" : "desktopcomputer")
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading) {
                    Text(device.displayName)
                        .font(.body)
                    Text(isPaired ? device.host : device.address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isPaired {
                    Text("Enter port")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .foregroundColor(.primary)
    }
}

struct AddDeviceSheet: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device Name (optional)", text: $store.deviceNameInput)
                    TextField("IP Address", text: $store.hostInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Port", text: $store.portInput)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.send(.addDevice)
                    }
                    .disabled(store.hostInput.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
