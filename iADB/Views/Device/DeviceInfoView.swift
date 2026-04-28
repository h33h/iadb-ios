import SwiftUI
import UIKit
import ComposableArchitecture

struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    @State private var showingRebootMenu = false
    @State private var showingExportSheet = false
    @State private var copiedSnapshot = false

    private var batteryDisplay: String {
        let level = store.details.batteryLevel
        let status = store.details.batteryStatus
        switch (level.isEmpty, status.isEmpty) {
        case (true, true): return ""
        case (false, true): return level
        case (true, false): return status
        case (false, false): return "\(level) · \(status)"
        }
    }

    private var batteryIcon: String {
        switch store.details.batteryStatus {
        case "Charging": return "battery.100.bolt"
        case "Full": return "battery.100"
        default: return "battery.75percent"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.isLoading {
                    StatusBannerView(style: .progress, message: "Loading device info...", showsProgress: true)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                if let error = store.errorMessage {
                    StatusBannerView(style: .error, message: error, actionTitle: "Retry", onAction: {
                        store.send(.fetchDeviceInfo)
                    })
                    .padding(.horizontal)
                    .padding(.top, store.isLoading ? 0 : 8)
                }

                if copiedSnapshot {
                    StatusBannerView(style: .success, message: "Device snapshot copied")
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                List {
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
                        InfoRow(label: "Battery", value: batteryDisplay, icon: batteryIcon)
                        InfoRow(label: "Screen", value: store.details.screenResolution, icon: "rectangle.dashed")
                        InfoRow(label: "RAM Total", value: store.details.totalMemory, icon: "memorychip")
                        InfoRow(label: "RAM Available", value: store.details.availableMemory, icon: "memorychip.fill")
                    }

                    if !store.details.ipAddress.isEmpty {
                        Section("Network") {
                            InfoRow(label: "IP Address", value: store.details.ipAddress, icon: "wifi")
                        }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !store.details.snapshotText.isEmpty {
                        Button {
                            UIPasteboard.general.string = store.details.snapshotText
                            withAnimation {
                                copiedSnapshot = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation {
                                    copiedSnapshot = false
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }

                        Button {
                            showingExportSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

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
            .sheet(isPresented: $showingExportSheet) {
                ShareTextSheet(text: store.details.snapshotText, fileName: "device-snapshot.txt")
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
