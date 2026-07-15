import SwiftUI

struct DeviceContextBar: View {
    let session: DeviceSessionFeature.State
    let activeOperationCount: Int
    var compact = false
    let onOpenSwitcher: () -> Void
    let onReconnect: () -> Void
    let onCancelReconnect: () -> Void
    let onOpenActivity: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || !compact {
                VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                    identityButton
                    actionRow
                }
            } else {
                HStack(spacing: IADBDesign.spacing8) {
                    identityButton
                    Spacer(minLength: IADBDesign.spacing4)
                    actionRow
                }
            }
        }
        .padding(.horizontal, IADBDesign.spacing12)
        .padding(.vertical, IADBDesign.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("device.context")
    }

    private var identityButton: some View {
        Button(action: onOpenSwitcher) {
            HStack(spacing: IADBDesign.spacing8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.selectedDevice?.displayName ?? String(localized: "No device selected"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(contextSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: IADBDesign.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Device context, \(session.selectedDevice?.displayName ?? String(localized: "no device")), \(statusTitle)"
        )
        .accessibilityHint("Opens the device switcher")
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: IADBDesign.spacing8) {
            switch session.transport {
            case .disconnected, .paired:
                Button(action: onReconnect) {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.bordered)
            case .reconnecting, .connecting:
                Button(action: onCancelReconnect) {
                    Label("Cancel", systemImage: "xmark")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.bordered)
            case .noDevice, .connected:
                EmptyView()
            }

            if activeOperationCount > 0 {
                Button(action: onOpenActivity) {
                    Label("\(activeOperationCount) active", systemImage: "clock.arrow.circlepath")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Activity, \(activeOperationCount) active operations")
                .accessibilityIdentifier("activity.open")
            }
        }
    }

    private var statusTitle: String {
        switch session.transport {
        case .noDevice: String(localized: "No device")
        case .paired: String(localized: "Paired")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .disconnected: String(localized: "Disconnected")
        }
    }

    private var contextSummary: String {
        switch session.transport {
        case .connected(let endpoint, _):
            "Connected · \(endpoint.displayValue)"
        case .reconnecting(let attempt, let endpoint):
            "Reconnecting · attempt \(attempt)\(endpoint.map { " · \($0.displayValue)" } ?? "")"
        case .disconnected(_, let lastSeen):
            lastSeen.map { "Disconnected · last seen \($0.formatted(.relative(presentation: .named)))" }
                ?? String(localized: "Disconnected")
        case .connecting:
            "Connecting…"
        case .paired:
            "Paired · not connected"
        case .noDevice:
            "Choose a nearby or saved device"
        }
    }

    private var statusSymbol: String {
        switch session.transport {
        case .connected: "checkmark.circle.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .disconnected: "wifi.slash"
        case .paired: "link.circle"
        case .noDevice: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch session.transport {
        case .connected: .green
        case .connecting, .reconnecting: .accentColor
        case .disconnected: .orange
        case .paired, .noDevice: .secondary
        }
    }
}

struct DeviceSwitcher: View {
    let session: DeviceSessionFeature.State
    let nearbyDevices: [DiscoveredDevice]
    let savedDevices: [PairedDevice]
    let onSelect: (DiscoveredDevice) -> Void
    let onManageConnections: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let device = session.selectedDevice {
                    Section("Current") {
                        LabeledContent(device.displayName, value: currentStatus)
                    }
                }

                Section("Nearby") {
                    if nearbyDevices.isEmpty {
                        ContentUnavailableView(
                            "No Nearby Devices",
                            systemImage: "wifi.slash",
                            description: Text("Open Wireless debugging on Android, then rescan in Connections.")
                        )
                    } else {
                        ForEach(nearbyDevices) { device in
                            Button {
                                onSelect(device)
                            } label: {
                                LabeledContent(device.name, value: "\(device.host):\(device.port)")
                            }
                            .frame(minHeight: IADBDesign.minimumHitTarget)
                        }
                    }
                }

                if !savedDevices.isEmpty {
                    Section("Saved") {
                        ForEach(savedDevices) { device in
                            LabeledContent(device.name, value: device.lastHost)
                                .accessibilityLabel("\(device.name), saved, offline")
                        }
                    }
                }

                Section {
                    Button("Manage Connections", systemImage: "network", action: onManageConnections)
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("device.switcher")
        }
        .frame(idealWidth: 400, idealHeight: 520)
        .presentationCompactAdaptation(.sheet)
    }

    private var currentStatus: String {
        switch session.transport {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting")
        case .reconnecting: String(localized: "Reconnecting")
        case .disconnected: String(localized: "Disconnected")
        case .paired: String(localized: "Paired")
        case .noDevice: String(localized: "Unavailable")
        }
    }
}
