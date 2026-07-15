import SwiftUI

private struct DesignSystemPreviewCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IADBDesign.spacing20) {
                WorkspaceToolbar {
                    VStack(alignment: .leading, spacing: IADBDesign.spacing4) {
                        Text("Files")
                            .font(.title2.weight(.semibold))
                        IADBStatusBadge(title: "Pixel Studio · Connected", kind: .success)
                    }
                } actions: {
                    Button("Upload", systemImage: "arrow.up") {}
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: IADBDesign.minimumHitTarget)
                }

                HStack(spacing: IADBDesign.spacing16) {
                    IADBStatusBadge(title: "Connected", kind: .success)
                    IADBStatusBadge(title: "Disconnected", kind: .warning)
                }

                IADBCard {
                    VStack(spacing: 0) {
                        TechnicalRow(
                            label: "Remote path",
                            value: "/storage/emulated/0/Download/Projects/An intentionally very long technical directory name",
                            icon: "folder",
                            monospacedValue: true,
                            allowsCopy: true
                        )
                        Divider()
                        TechnicalRow(
                            label: "Package",
                            value: "com.example.precision.utility.extremely.long.identifier",
                            icon: "shippingbox",
                            monospacedValue: true,
                            allowsCopy: true
                        )
                    }
                }

                HStack {
                    LabeledMetric(title: "Battery", value: "82%", symbol: "battery.75", tint: .green)
                    LabeledMetric(title: "Storage", value: "71.4 GB free", symbol: "internaldrive")
                }

                FilterSummaryButton("Packages", summary: "User · Name", activeCount: 2) {
                    Button("User") {}
                    Button("System") {}
                }

                InlineValidatedField(
                    "Pairing port",
                    symbol: "number",
                    validationMessage: "Use the pairing port shown in Android, not the connection port."
                ) {
                    TextField("37000", text: .constant("37000"))
                        .fontDesign(.monospaced)
                }

                ProgressRow(
                    operation: BackgroundOperation(
                        id: UUID(0),
                        deviceID: "preview-device",
                        deviceName: "Pixel Studio with a long device name",
                        workspace: .files,
                        kind: .upload,
                        objectName: "large-fixture-archive.zip",
                        phase: .running,
                        completedUnits: 41,
                        totalUnits: 100,
                        detail: "Keep iADB in the foreground while this transfer completes.",
                        isCancellable: true,
                        isTransportDependent: true,
                        cleanupState: .notRequired,
                        outcome: nil,
                        retryPayload: nil,
                        startedAt: .distantPast,
                        finishedAt: nil
                    ),
                    onCancel: {},
                    onRetry: nil
                )

                DetailInspector(
                    state: .empty(
                        title: "No Selection",
                        message: "Choose an item to inspect metadata and available actions.",
                        symbol: "sidebar.right"
                    )
                ) { EmptyView() }
                .frame(minHeight: 140)

                BulkActionBar(
                    selectionCount: 3,
                    selectionLabel: String(localized: "3 items"),
                    actions: [
                        BulkActionItem(
                            id: "share",
                            title: "Share",
                            symbol: "square.and.arrow.up",
                            emphasis: .secondary,
                            action: {}
                        ),
                        BulkActionItem(
                            id: "delete",
                            title: "Delete",
                            symbol: "trash",
                            emphasis: .destructive,
                            action: {}
                        )
                    ]
                )
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

#Preview("Light · Compact") {
    DesignSystemPreviewCatalog()
        .preferredColorScheme(.light)
}

#Preview("Dark · Regular") {
    DesignSystemPreviewCatalog()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 900)
}

#Preview("Increased Contrast") {
    DesignSystemPreviewCatalog()
        .environment(\.iadbIncreasedContrastPreview, true)
}

#Preview("Accessibility XXXL · Reduce Motion") {
    DesignSystemPreviewCatalog()
        .environment(\.dynamicTypeSize, .accessibility5)
}
