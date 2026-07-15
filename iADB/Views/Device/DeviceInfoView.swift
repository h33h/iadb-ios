import SwiftUI
import UIKit
import ComposableArchitecture

struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    var isEmbeddedInNavigationStack = true
    var lastUpdated: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingRebootMenu = false
    @State private var rebootConfirmations: [String: DestructiveActionConfirmation] = [:]
    @State private var showingExportSheet = false
    @State private var copiedSnapshot = false
    @State private var rawPropertiesExpanded = false

    init(
        store: StoreOf<DeviceInfoFeature>,
        isEmbeddedInNavigationStack: Bool = true,
        lastUpdated: Date? = nil
    ) {
        self.store = store
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.lastUpdated = lastUpdated
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
            if store.isLoading || store.isRebooting || store.rebootStatusMessage != nil || store.errorMessage != nil || copiedSnapshot {
                Section {
                    VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                        statusArea
                    }
                }
            }

            Section("Device") {
                LabeledContent("Model", value: store.details.displayTitle)
                LabeledContent("Status") {
                    IADBStatusBadge(
                        title: store.remoteTarget.isConnected
                            ? String(localized: "Connected")
                            : String(localized: "Last known"),
                        kind: store.remoteTarget.isConnected ? .success : .warning
                    )
                }
            }

            Section("Identity") {
                TechnicalRow(label: "Manufacturer", value: store.details.manufacturer)
                TechnicalRow(label: "Device Name", value: store.details.deviceName, allowsCopy: true)
                TechnicalRow(label: "Serial Number", value: store.details.serialNumber, monospacedValue: true, allowsCopy: true)
            }

            Section("System") {
                LabeledContent("Android Version", value: store.details.androidVersion.isEmpty ? "—" : store.details.androidVersion)
                LabeledContent("SDK Level", value: store.details.sdkVersion.isEmpty ? "—" : store.details.sdkVersion)
                TechnicalRow(label: "Build", value: store.details.buildFingerprint, monospacedValue: true, allowsCopy: true)
            }

            Section("Hardware") {
                LabeledContent("Battery", value: batteryDisplay.isEmpty ? "—" : batteryDisplay)
                LabeledContent("Screen", value: store.details.screenResolution.isEmpty ? "—" : store.details.screenResolution)
                LabeledContent("Memory", value: capacitySummary(available: store.details.availableMemory, total: store.details.totalMemory))
                LabeledContent("Storage", value: capacitySummary(available: store.details.availableStorage, total: store.details.totalStorage))
            }

            Section("Network") {
                TechnicalRow(label: "IP Address", value: store.details.ipAddress, monospacedValue: true, allowsCopy: true)
            }

            Section {
                DisclosureGroup("Raw Properties", isExpanded: $rawPropertiesExpanded) {
                    TechnicalRow(label: "CPU ABI", value: store.details.cpuAbi, monospacedValue: true, allowsCopy: true)
                    TechnicalRow(label: "Build Fingerprint", value: store.details.buildFingerprint, monospacedValue: true, allowsCopy: true)
                    TechnicalRow(label: "Android Device Name", value: store.details.deviceName, monospacedValue: true, allowsCopy: true)
                }
            } footer: {
                if let lastUpdated {
                    Text("Refreshed \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Refresh to update device properties.")
                }
            }

            Section {
                Button(role: .destructive) {
                    rebootConfirmations = Dictionary(uniqueKeysWithValues: ["", "recovery", "bootloader"].compactMap { mode in
                        store.remoteTarget.confirmation(for: "reboot:\(mode)").map { (mode, $0) }
                    })
                    showingRebootMenu = true
                } label: {
                    Label("Reboot \(store.remoteTarget.deviceName)", systemImage: "arrow.clockwise.circle")
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }
                .disabled(store.isRebooting || !store.remoteTarget.isConnected)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Reboot disconnects the current ADB session. Choose the boot mode only after confirming the target device.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(IADBScreenBackground())
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("Reboot Mode", isPresented: $showingRebootMenu) {
            Button("Normal Reboot") {
                store.send(.reboot(mode: "", confirmation: rebootConfirmations[""]))
            }
            Button("Recovery") {
                store.send(.reboot(
                    mode: "recovery",
                    confirmation: rebootConfirmations["recovery"]
                ))
            }
            Button("Bootloader") {
                store.send(.reboot(
                    mode: "bootloader",
                    confirmation: rebootConfirmations["bootloader"]
                ))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.remoteTarget.deviceName) will restart and the current ADB session will disconnect.")
        }
        .sheet(isPresented: $showingExportSheet) {
            ShareTextSheet(text: store.details.snapshotText, fileName: "device-snapshot.txt")
        }
    }

    private func capacitySummary(available: String, total: String) -> String {
        switch (available.isEmpty, total.isEmpty) {
        case (true, true): "—"
        case (false, true): String(localized: "\(available) available")
        case (true, false): total
        case (false, false): String(localized: "\(available) of \(total) free")
        }
    }

    /*
     Legacy card helpers remain below while downstream screen slices migrate
     their previews. The live Device Details composition above is a native List.
     */
    private var legacyCardContent: some View {
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
            .iadbReadableWidth(maxWidth: 820)
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if store.isLoading {
            StatusBannerView(
                style: .progress,
                message: String(localized: "Loading device info…"),
                showsProgress: true
            )
        }

        if store.isRebooting {
            StatusBannerView(
                style: .progress,
                message: String(localized: "Sending reboot command…"),
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
            StatusBannerView(style: .success, message: String(localized: "Device snapshot copied"))
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
            LabeledMetric(
                title: "Android",
                value: store.details.androidVersion,
                symbol: "a.square.fill",
                tint: .green
            )
            LabeledMetric(
                title: "Battery",
                value: batteryDisplay,
                symbol: batteryIcon,
                tint: batteryTint
            )
            LabeledMetric(
                title: "Available RAM",
                value: store.details.availableMemory,
                symbol: "memorychip.fill",
                tint: .purple
            )
            LabeledMetric(
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
                    rebootConfirmations = Dictionary(uniqueKeysWithValues: ["", "recovery", "bootloader"].compactMap { mode in
                        store.remoteTarget.confirmation(for: "reboot:\(mode)").map { (mode, $0) }
                    })
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
        announceAccessibility("Device snapshot copied")
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
        return parts.isEmpty
            ? String(localized: "Android device information")
            : parts.joined(separator: " · ")
    }

    private var batteryDisplay: String {
        let level = store.details.batteryLevel
        let status = store.details.localizedBatteryStatus
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
        case .fetch: String(localized: "Retry Refresh")
        case nil: nil
        }
    }
}

private struct DeviceInfoItem {
    let label: String
    let value: String
    var icon: String?

    init(label: LocalizedStringResource, value: String, icon: String? = nil) {
        self.label = String(localized: label)
        self.value = value
        self.icon = icon
    }
}

private struct DeviceInfoSection: View {
    let title: String
    let symbol: String
    let rows: [DeviceInfoItem]

    init(title: LocalizedStringResource, symbol: String, rows: [DeviceInfoItem]) {
        self.title = String(localized: title)
        self.symbol = symbol
        self.rows = rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing) {
            IADBSectionHeader(localizedTitle: title) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            IADBCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        TechnicalRow(
                            localizedLabel: row.label,
                            value: row.value,
                            icon: row.icon,
                            monospacedValue: row.label == "Serial" || row.label == "Build Fingerprint",
                            allowsCopy: true
                        )
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
