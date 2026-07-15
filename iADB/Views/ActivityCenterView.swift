import SwiftUI
import UIKit
import ComposableArchitecture

struct StatusBannerPresenter: View {
    let feedback: UserFeedback
    let onDismiss: () -> Void
    let onRecovery: (FeedbackRecovery) -> Void

    var body: some View {
        if case .banner(_, let severity, let message, let recovery) = feedback {
            StatusBannerView(
                style: style(for: severity),
                message: message,
                showsProgress: severity == .reconnecting,
                actionTitle: recovery.map(actionTitle),
                onDismiss: onDismiss,
                onAction: recovery.map { recovery in { onRecovery(recovery) } }
            )
        }
    }

    private func style(for severity: FeedbackSeverity) -> StatusBannerStyle {
        switch severity {
        case .information: .info
        case .reconnecting: .progress
        case .operationFailure, .connectionError, .permissionDenied: .error
        }
    }

    private func actionTitle(for recovery: FeedbackRecovery) -> String {
        switch recovery {
        case .reconnect: String(localized: "Reconnect")
        case .retryOperation: String(localized: "Retry")
        case .openSettings: String(localized: "Open Settings")
        case .details: String(localized: "Details")
        }
    }
}

struct ActivityCenterView: View {
    let store: StoreOf<OperationCenterFeature>

    var body: some View {
        NavigationStack {
            List {
                if !store.activeOperations.isEmpty {
                    Section("Active") {
                        ForEach(store.activeOperations) { operation in
                            ProgressRow(
                                operation: operation,
                                onCancel: operation.isCancellable
                                    ? { store.send(.cancelTapped(operation.id)) }
                                    : nil,
                                onRetry: nil
                            )
                        }
                    }
                }

                if !store.completedOperations.isEmpty {
                    Section("Recent") {
                        ForEach(store.completedOperations) { operation in
                            ProgressRow(
                                operation: operation,
                                onCancel: nil,
                                onRetry: operation.canRetry
                                    ? { store.send(.retryTapped(operation.id)) }
                                    : nil
                            )
                        }
                    }
                }

                Section {
                    Label(
                        "Keep iADB in the foreground during large transfers and installs. iOS may suspend work after you leave the app.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("activity.foreground.message")
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.setPresented(false)) }
                }
            }
            .accessibilityIdentifier("activity.center")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ProgressRow: View {
    let operation: BackgroundOperation
    let onCancel: (() -> Void)?
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.objectName)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("activity.operation.object")
                    Text("\(operation.deviceName) · \(phaseLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity.operation.device-phase")
                }
                Spacer(minLength: 8)
                if let progress = operation.progressFraction {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = operation.progressFraction {
                ProgressView(value: progress)
                    .accessibilityLabel("Operation progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            } else if operation.isActive {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(phaseLabel)
            }

            if let detail = operation.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            outcomeView

            if onCancel != nil || onRetry != nil {
                HStack(spacing: 10) {
                    if let onCancel {
                        Button("Cancel", role: .destructive, action: onCancel)
                            .frame(minHeight: 44)
                    }
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch operation.outcome {
        case .success(let summary):
            Label(summary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message, _):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private var phaseLabel: String {
        switch operation.phase {
        case .queued: String(localized: "Queued")
        case .preparing: String(localized: "Preparing")
        case .running: String(localized: "Running")
        case .cleaningUp: String(localized: "Cleaning up")
        case .finished: String(localized: "Finished")
        }
    }

    private var symbol: String {
        switch operation.kind {
        case .upload: "arrow.up.circle"
        case .download: "arrow.down.circle"
        case .installAPK: "shippingbox"
        case .fileMutation: "folder.badge.gearshape"
        case .appMutation: "square.stack.3d.up.badge.xmark"
        case .export: "square.and.arrow.up"
        case .capture: "camera.viewfinder"
        }
    }

    private var tint: Color {
        if case .failure = operation.outcome { return .red }
        if case .success = operation.outcome { return .green }
        return .accentColor
    }
}

struct FeedbackToast: View {
    let feedback: UserFeedback

    var body: some View {
        if case .toast(_, let message, let symbol) = feedback {
            Label(message, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
        }
    }
}
