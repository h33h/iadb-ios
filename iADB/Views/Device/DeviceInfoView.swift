import SwiftUI
import ComposableArchitecture

struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    @State private var showingRebootMenu = false

    var body: some View {
        NavigationStack {
            List {
                if store.isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading device info...")
                            Spacer()
                        }
                    }
                } else if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Button("Retry") {
                            store.send(.fetchDeviceInfo)
                        }
                    }
                } else {
                    // Identity
                    Section("Identity") {
                        InfoRow(label: "Model", value: store.details.model)
                        InfoRow(label: "Manufacturer", value: store.details.manufacturer)
                        InfoRow(label: "Device Name", value: store.details.deviceName)
                        InfoRow(label: "Serial Number", value: store.details.serialNumber)
                    }

                    // System
                    Section("System") {
                        InfoRow(label: "Android Version", value: store.details.androidVersion)
                        InfoRow(label: "SDK Level", value: store.details.sdkVersion)
                        InfoRow(label: "CPU ABI", value: store.details.cpuAbi)
                        InfoRow(label: "Build", value: store.details.buildFingerprint)
                    }

                    // Hardware
                    Section("Hardware") {
                        InfoRow(label: "Battery", value: store.details.batteryLevel, icon: "battery.75percent")
                        InfoRow(label: "Screen", value: store.details.screenResolution, icon: "rectangle.dashed")
                    }

                    // Actions
                    Section("Actions") {
                        Button {
                            showingRebootMenu = true
                        } label: {
                            Label("Reboot Device", systemImage: "arrow.clockwise.circle")
                        }
                    }
                }
            }
            .navigationTitle("Device Info")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.fetchDeviceInfo)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .confirmationDialog("Reboot Mode", isPresented: $showingRebootMenu) {
                Button("Normal Reboot") {
                    store.send(.reboot(mode: ""))
                }
                Button("Recovery") {
                    store.send(.reboot(mode: "recovery"))
                }
                Button("Bootloader") {
                    store.send(.reboot(mode: "bootloader"))
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
            }
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
        .contextMenu {
            if !value.isEmpty {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
