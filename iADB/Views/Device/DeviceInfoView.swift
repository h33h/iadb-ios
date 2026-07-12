import SwiftUI
import UIKit
import ComposableArchitecture

struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    var isEmbeddedInNavigationStack = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingRebootMenu = false
    @State private var showingExportSheet = false
    @State private var copiedSnapshot = false

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                statusArea
                identityHero
                metricsGrid

                DeviceInfoSection(
                    title: "Identity",
                    symbol: "person.text.rectangle",
                    rows: [
                        .init(label: "Model", value: store.details.model),
                        .init(label: "Manufacturer", value: store.details.manufacturer),
                        .init(label: "Device Name", value: store.details.deviceName),
                        .init(label: "Serial Number", value: store.details.serialNumber),
                    ]
                )

                DeviceInfoSection(
                    title: "System",
                    symbol: "cpu",
                    rows: [
                        .init(label: "Android Version", value: store.details.androidVersion),
                        .init(label: "SDK Level", value: store.details.sdkVersion),
                        .init(label: "CPU ABI", value: store.details.cpuAbi),
                        .init(label: "Build", value: store.details.buildFingerprint),
                    ]
                )

                DeviceInfoSection(
                    title: "Hardware",
                    symbol: "memorychip",
                    rows: [
                        .init(label: "Battery", value: batteryDisplay, icon: batteryIcon),
                        .init(label: "Screen", value: store.details.screenResolution, icon: "rectangle.dashed"),
                        .init(label: "RAM Total", value: store.details.totalMemory, icon: "memorychip"),
                        .init(label: "RAM Available", value: store.details.availableMemory, icon: "memorychip.fill"),
                    ]
                )

                if !store.details.ipAddress.isEmpty {
                    DeviceInfoSection(
                        title: "Network",
                        symbol: "wifi",
                        rows: [
                            .init(label: "IP Address", value: store.details.ipAddress, icon: "network"),
                        ]
                    )
                }

                actionsCard
            }
            .padding(IADBDesign.contentPadding)
            .padding(.bottom, 24)
            .iadbContentWidth()
        }
        .background(IADBScreenBackground())
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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
        } message: {
            Text("The current ADB session will disconnect while Android restarts.")
        }
        .sheet(isPresented: $showingExportSheet) {
            ShareTextSheet(text: store.details.snapshotText, fileName: "device-snapshot.txt")
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if store.isLoading {
            StatusBannerView(style: .progress, message: "Loading device info…", showsProgress: true)
        }

        if store.isRebooting {
            StatusBannerView(
                style: .progress,
                message: "Sending reboot command…",
                showsProgress: true
            )
        } else if let rebootStatus = store.rebootStatusMessage {
            StatusBannerView(style: .success, message: rebootStatus)
        }

        if let error = store.errorMessage {
            StatusBannerView(
                style: .error,
                message: error,
                actionTitle: errorRecoveryTitle,
                onDismiss: { store.send(.dismissError) },
                onAction: errorRecoveryTitle == nil ? nil : { store.send(.retryError) }
            )
        }

        if copiedSnapshot {
            StatusBannerView(style: .success, message: "Device snapshot copied")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private var identityHero: some View {
        IADBCard {
            identityHeroLayout
        }
    }

    @ViewBuilder
    private var identityHeroLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            identityHeroVertical
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    identityHeroIcon
                    identityHeroText
                    Spacer(minLength: 0)
                }

                identityHeroVertical
            }
        }
    }

    private var identityHeroVertical: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityHeroIcon
            identityHeroText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityHeroIcon: some View {
        Image(systemName: "smartphone")
            .font(.largeTitle)
            .foregroundStyle(Color.accentColor)
            .frame(width: 64, height: 64)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var identityHeroText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.details.displayTitle)
                .font(.title2.weight(.bold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text(deviceSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            IADBStatusBadge(
                title: store.isLoading ? "Refreshing" : "ADB Connected",
                kind: store.isLoading ? .progress : .success
            )
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 145),
                    spacing: IADBDesign.spacing
                )
            ],
            spacing: IADBDesign.spacing
        ) {
            IADBMetricCard(
                title: "Android",
                value: store.details.androidVersion,
                symbol: "a.square.fill",
                tint: .green
            )
            IADBMetricCard(
                title: "Battery",
                value: batteryDisplay,
                symbol: batteryIcon,
                tint: batteryTint
            )
            IADBMetricCard(
                title: "Available RAM",
                value: store.details.availableMemory,
                symbol: "memorychip.fill",
                tint: .purple
            )
            IADBMetricCard(
                title: "Display",
                value: store.details.screenResolution,
                symbol: "rectangle.dashed",
                tint: .blue
            )
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader("Device Actions")
            IADBCard {
                Button {
                    showingRebootMenu = true
                } label: {
                    HStack(spacing: IADBDesign.spacing) {
                        IADBIconTile(symbol: "arrow.clockwise.circle", tint: .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reboot Device")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("Restart normally, into recovery, or into the bootloader")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isRebooting)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !store.details.snapshotText.isEmpty {
                Button {
                    UIPasteboard.general.string = store.details.snapshotText
                    showCopiedConfirmation()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy device snapshot")

                Button {
                    showingExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share device snapshot")
            }

            Button {
                store.send(.fetchDeviceInfo)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isLoading || store.isRebooting)
            .accessibilityLabel("Refresh device info")
        }
    }

    private func showCopiedConfirmation() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            copiedSnapshot = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                copiedSnapshot = false
            }
        }
    }

    private var deviceSubtitle: String {
        let parts = [store.details.manufacturer, store.details.deviceName]
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Android device information" : parts.joined(separator: " · ")
    }

    private var batteryDisplay: String {
        let level = store.details.batteryLevel
        let status = store.details.batteryStatus
        return switch (level.isEmpty, status.isEmpty) {
        case (true, true): ""
        case (false, true): level
        case (true, false): status
        case (false, false): "\(level) · \(status)"
        }
    }

    private var batteryIcon: String {
        switch store.details.batteryStatus {
        case "Charging": "battery.100.bolt"
        case "Full": "battery.100"
        default: "battery.75percent"
        }
    }

    private var batteryTint: Color {
        switch store.details.batteryStatus {
        case "Charging", "Full": .green
        default: .orange
        }
    }

    private var errorRecoveryTitle: String? {
        switch store.errorRecovery {
        case .fetch: "Retry Refresh"
        case .reboot: "Retry Reboot"
        case nil: nil
        }
    }
}

private struct DeviceInfoItem {
    let label: String
    let value: String
    var icon: String?
}

private struct DeviceInfoSection: View {
    let title: String
    let symbol: String
    let rows: [DeviceInfoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader(title) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            IADBCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        InfoRow(label: row.label, value: row.value, icon: row.icon)
                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, row.icon == nil ? 0 : 34)
                        }
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var icon: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: IADBDesign.compactSpacing) {
            accessibleInformation

            if !value.isEmpty {
                copyMenu
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var accessibleInformation: some View {
        if value.isEmpty {
            information
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label), not available")
        } else {
            information
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label), \(value)")
                .accessibilityAction(named: "Copy \(label)") {
                    copyValue()
                }
        }
    }

    @ViewBuilder
    private var information: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: IADBDesign.compactSpacing) {
                labelView
                valueView
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: IADBDesign.compactSpacing) {
                labelView
                Spacer(minLength: 12)
                valueView
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var labelView: some View {
        HStack(alignment: .firstTextBaseline, spacing: IADBDesign.compactSpacing) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var valueView: some View {
        Text(value.isEmpty ? "—" : value)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var copyMenu: some View {
        Menu {
            Button {
                copyValue()
            } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Copy \(label)")
        .accessibilityHint("Opens copy actions")
    }

    private func copyValue() {
        UIPasteboard.general.string = value
    }
}
