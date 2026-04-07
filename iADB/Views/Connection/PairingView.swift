import SwiftUI
import ComposableArchitecture

struct PairingView: View {
    @Bindable var store: StoreOf<PairingFeature>
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Android 11+ Wireless Debugging", systemImage: "wifi.circle")
                            .font(.subheadline.bold())
                        Text("On your Android device, go to Developer Options > Wireless debugging and tap 'Pair device with pairing code'.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Instructions")
                }

                Section {
                    TextField("IP Address", text: $store.hostInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Pairing Port", text: $store.portInput)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Pairing Address")
                } footer: {
                    Text("Enter the IP address and port shown in the 'Pair device with pairing code' dialog.")
                }

                Section {
                    TextField("Connection Port", text: $store.connectionPortInput)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Connection Port")
                } footer: {
                    Text("Port shown on the main 'Wireless debugging' screen (not the pairing port). The device will be saved for future connections.")
                }

                Section {
                    TextField("6-digit code", text: $store.pairingCode)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .multilineTextAlignment(.center)
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("Enter the 6-digit code shown on the Android device.")
                }

                Section {
                    Button {
                        store.send(.pairWithCode)
                    } label: {
                        HStack {
                            Spacer()
                            if store.pairingState.isPairing {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Pairing...")
                            } else {
                                Image(systemName: "link.badge.plus")
                                Text("Pair Device")
                            }
                            Spacer()
                        }
                        .font(.headline)
                    }
                    .disabled(
                        store.hostInput.isEmpty ||
                        store.portInput.isEmpty ||
                        store.pairingCode.count != 6 ||
                        store.pairingState.isPairing
                    )
                }

                // Status
                switch store.pairingState {
                case .idle, .pairing:
                    EmptyView()
                case .success(let message):
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(message)
                                .font(.subheadline)
                        }
                        Text("You can now connect to the device using the IP and the wireless debugging port (not the pairing port).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                case .error(let message):
                    Section {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            })
        }
    }
}
