import SwiftUI
import ComposableArchitecture

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
                    intro
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
            .interactiveDismissDisabled(store.pairingState.isPairing)
            .onDisappear { store.send(.cancelPairing) }
        }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text("Pair over local Wi-Fi")
                    .font(.title3.weight(.semibold))
                Text("On Android 11 or later, open Developer options › Wireless debugging › Pair device with pairing code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
    }

    private var addressStep: some View {
        pairingCard(step: "1", title: "Pairing address", subtitle: addressSubtitle) {
            VStack(spacing: 12) {
                LabeledContent {
                    TextField("192.168.1.42", text: $store.hostInput)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                        .disabled(store.isPrefilled || store.pairingState.isPairing)
                        .accessibilityLabel("IP address")
                } label: {
                    Label("IP address", systemImage: "network")
                }

                Divider()

                LabeledContent {
                    TextField("37000", text: $store.portInput)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .fontDesign(.monospaced)
                        .focused($focusedField, equals: .port)
                        .disabled(store.isPrefilled || store.pairingState.isPairing)
                        .accessibilityLabel("Pairing port")
                } label: {
                    Label("Pairing port", systemImage: "number")
                }
            }
        }
    }

    private var codeStep: some View {
        pairingCard(
            step: "2",
            title: "Pairing code",
            subtitle: "Enter the six digits shown in the same Android dialog."
        ) {
            TextField("000000", text: $store.pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .code)
                .disabled(store.pairingState.isPairing)
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Six digit pairing code")
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch store.pairingState {
        case .idle:
            EmptyView()
        case .pairing:
            Label("Creating a secure pairing…", systemImage: "lock.shield")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .success(let message):
            statusCard(
                title: message,
                message: "Pairing is complete. Use Android's regular Wireless debugging port for the connection.",
                icon: "checkmark.circle.fill",
                tint: .green
            )
        case .error(let message):
            statusCard(
                title: "Pairing failed",
                message: message,
                icon: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            if store.pairingState.isPairing {
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
                Button {
                    focusedField = nil
                    store.send(.pairWithCode)
                } label: {
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
            && !store.pairingState.isPairing
    }

    private var addressSubtitle: String {
        store.isPrefilled
            ? "iADB found this pairing service. Confirm the address and enter the code."
            : "Copy the IP address and pairing port from the Android pairing dialog."
    }

    private func pairingCard<Content: View>(
        step: String,
        title: String,
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
