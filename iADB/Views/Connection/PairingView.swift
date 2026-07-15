import SwiftUI
import ComposableArchitecture
import UIKit

struct PairingView: View {
    @Bindable var store: StoreOf<PairingFeature>
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case port
        case code
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    addressStep
                    codeStep
                    pairingStatus
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.send(.cancelPairing)
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
            .interactiveDismissDisabled(store.isBusy)
        }
    }

    private var addressStep: some View {
        pairingCard(step: "1", title: "Pairing address", subtitle: addressSubtitle) {
            VStack(spacing: 12) {
                InlineValidatedField("IP address", symbol: "network", validationMessage: store.hostValidationError) {
                    TextField("192.168.1.42", text: $store.hostInput)
                        .accessibilityIdentifier("pairing.host")
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                        .disabled(store.isPrefilled || store.isBusy)
                        .accessibilityLabel("IP address")
                }

                Divider()

                InlineValidatedField("Pairing port", symbol: "number", validationMessage: store.portValidationError) {
                    TextField("37000", text: $store.portInput)
                        .accessibilityIdentifier("pairing.port")
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .fontDesign(.monospaced)
                        .focused($focusedField, equals: .port)
                        .disabled(store.isPrefilled || store.isBusy)
                        .accessibilityLabel("Pairing port")
                }
            }
        }
    }

    private var codeStep: some View {
        pairingCard(
            step: "2",
            title: "Pairing code",
            subtitle: String(localized: "Enter the six digits shown in the same Android dialog.")
        ) {
            VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                ZStack {
                    HStack(spacing: IADBDesign.spacing8) {
                        ForEach(0..<6, id: \.self) { index in
                            Text(codeDigit(at: index))
                                .font(.title2.monospacedDigit().weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: IADBDesign.controlRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: IADBDesign.controlRadius)
                                        .stroke(
                                            focusedField == .code && index == min(store.pairingCode.count, 5)
                                                ? Color.accentColor
                                                : Color.clear,
                                            lineWidth: 2
                                        )
                                }
                                .accessibilityHidden(true)
                        }
                    }

                    TextField("", text: $store.pairingCode)
                        .accessibilityIdentifier("pairing.code")
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .code)
                        .disabled(store.isBusy)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Six digit pairing code")
                        .accessibilityValue(
                            store.pairingCode.isEmpty
                                ? String(localized: "Empty")
                                : String(localized: "\(store.pairingCode.count) of 6 digits entered")
                        )
                }

                if let error = store.codeValidationError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch store.pairingState {
        case .idle:
            EmptyView()
        case .pairing:
            Label(pairingPhaseTitle, systemImage: "lock.shield")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let message):
            statusCard(
                title: message,
                message: String(localized: "Pairing is complete. Connecting through Android's regular Wireless debugging endpoint…"),
                icon: "checkmark.circle.fill",
                tint: .green
            )
        case .error(let message):
            statusCard(
                title: String(localized: "Pairing failed"),
                message: message,
                icon: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            if store.phase == .connecting {
                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(true)
            } else if store.pairingState.isPairing {
                Button("Cancel") { store.send(.cancelPairing) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)

                Button(action: {}) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Pairing…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(true)
            } else {
                Button(action: submitPairing) {
                    Label("Pair Device", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!canPair)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canPair: Bool {
        !store.hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.portInput.isEmpty
            && store.pairingCode.count == 6
            && !store.isBusy
    }

    private var addressSubtitle: String {
        store.isPrefilled
            ? String(localized: "iADB found this pairing service. Confirm the address and enter the code.")
            : String(localized: "Enter the IP address and pairing port shown in the Android pairing dialog.")
    }

    private func submitPairing() {
        guard canPair else { return }
        focusedField = nil
        store.send(.pairWithCode)
    }

    private var pairingPhaseTitle: String {
        switch store.phase {
        case .idle: String(localized: "Ready to pair")
        case .validating: String(localized: "Validating address and code…")
        case .negotiating: String(localized: "Negotiating secure pairing…")
        case .connecting: String(localized: "Connecting to the paired device…")
        }
    }

    private func codeDigit(at index: Int) -> String {
        guard index < store.pairingCode.count else { return " " }
        let stringIndex = store.pairingCode.index(store.pairingCode.startIndex, offsetBy: index)
        return String(store.pairingCode[stringIndex])
    }

    private func pairingCard<Content: View>(
        step: String,
        title: LocalizedStringResource,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(step)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
    }

    private func statusCard(title: String, message: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
