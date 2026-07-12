import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    var isEmbeddedInNavigationStack = false

    @State private var showingOpenSourceLicenses = false
    @State private var showingPrivacyPolicy = false

    private enum Route: Hashable {
        case connectionGuide
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
            Section {
                NavigationLink(value: Route.connectionGuide) {
                    SettingsRow(
                        title: "Connection Guide",
                        subtitle: "Set up Wireless debugging step by step",
                        symbol: "questionmark.circle",
                        tint: .accentColor
                    )
                }
                .accessibilityLabel("Connection Guide")
                .accessibilityHint("Opens Wireless debugging setup instructions")

                if let supportURL = URL(string: "https://github.com/h33h/iadb-ios/issues") {
                    Link(destination: supportURL) {
                        SettingsRow(
                            title: "Support",
                            subtitle: "Report an issue or ask for help",
                            symbol: "lifepreserver",
                            tint: .blue
                        )
                    }
                    .accessibilityLabel("Support")
                    .accessibilityHint("Opens the iADB support page")
                }
            } header: {
                Text("Help")
            }

            Section {
                Button {
                    showingPrivacyPolicy = true
                } label: {
                    SettingsRow(
                        title: "Privacy Policy",
                        subtitle: "How iADB handles device data",
                        symbol: "hand.raised",
                        tint: .green
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Privacy Policy")
                .accessibilityHint("Opens the in-app privacy policy")

                Button {
                    showingOpenSourceLicenses = true
                } label: {
                    SettingsRow(
                        title: "Open Source Licenses",
                        subtitle: "Third-party software acknowledgements",
                        symbol: "doc.text",
                        tint: .indigo
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Open Source Licenses")
                .accessibilityHint("Shows third-party software licenses")
            } header: {
                Text("Legal")
            }

            Section {
                Button(role: .destructive) {
                    store.send(.requestResetADBIdentity)
                } label: {
                    SettingsRow(
                        title: "Reset ADB Identity",
                        subtitle: "Remove the ADB key and forget every device",
                        symbol: "key.slash",
                        tint: .red
                    )
                }
                .accessibilityLabel("Reset ADB Identity")
                .accessibilityHint("Removes the ADB key and forgets saved devices")
            } header: {
                Text("Security")
            } footer: {
                Text(
                    "Reset only removes trust from this iPhone or iPad. To revoke it completely, "
                        + "also remove iADB from Android's Wireless debugging paired devices."
                )
            }

            #if DEBUG
            Section {
                Button {
                    store.send(.showDebugSettings)
                } label: {
                    SettingsRow(
                        title: "Android Emulator",
                        subtitle: "Configure the local debug endpoint",
                        symbol: "hammer",
                        tint: .orange
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Android Emulator")
            } header: {
                Text("Development")
            }
            #endif

            Section {
                LabeledContent("Version", value: versionText)
            } header: {
                Text("About iADB")
            } footer: {
                Text("A private, local-network ADB utility for iPhone and iPad.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(IADBScreenBackground())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .connectionGuide:
                ConnectionGuideView()
            }
        }
        .alert(
            "Reset ADB Identity?",
            isPresented: Binding(
                get: { store.isResetIdentityConfirmationPresented },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelResetADBIdentity)
                    }
                }
            )
        ) {
            Button("Reset Identity", role: .destructive) {
                store.send(.confirmResetADBIdentity)
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelResetADBIdentity)
            }
        } message: {
            Text(
                "This removes the ADB key from Keychain, forgets every saved device, and disconnects. "
                    + "You will need to pair again."
            )
        }
        .sheet(isPresented: $showingOpenSourceLicenses) {
            OpenSourceLicensesView()
        }
        .sheet(isPresented: $showingPrivacyPolicy) {
            PrivacyPolicyView()
        }
        #if DEBUG
        .sheet(
            isPresented: Binding(
                get: { store.debugSettingsPresented },
                set: { isPresented in
                    if isPresented {
                        store.send(.showDebugSettings)
                    } else {
                        store.send(.hideDebugSettings)
                    }
                }
            )
        ) {
            DebugSettingsSheet(store: store)
        }
        #endif
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (.some(version), .some(build)): "\(version) (\(build))"
        case let (.some(version), .none): version
        default: "—"
        }
    }
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: IADBDesign.spacing) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionGuideView: View {
    private let steps: [(String, String, String)] = [
        (
            "gearshape.2",
            "Enable developer options",
            "On Android, open Settings › About phone and tap Build number seven times."
        ),
        (
            "wifi",
            "Turn on Wireless debugging",
            "Open Developer options, enable Wireless debugging, and keep both devices on the same Wi-Fi."
        ),
        (
            "number",
            "Open a pairing code",
            "Tap “Pair device with pairing code”. Keep this Android dialog open while entering its details in iADB."
        ),
        (
            "link",
            "Pair, then connect",
            "The pairing port and normal Wireless debugging port are different. iADB will guide you if a second address is needed."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IADBDesign.sectionSpacing) {
                IADBCard {
                    IADBCallout(
                        title: "Before You Start",
                        message: "Wireless debugging requires Android 11 or later and a local Wi-Fi network.",
                        symbol: "checkmark.shield"
                    )
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    IADBCard {
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                IADBIconTile(symbol: step.0)
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.accentColor, in: Circle())
                                    .offset(x: 17, y: -17)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.1)
                                    .font(.headline)
                                Text(step.2)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1), \(step.1). \(step.2)")
                    }
                }
            }
            .padding(IADBDesign.contentPadding)
            .padding(.bottom, 24)
            .iadbContentWidth()
        }
        .background(IADBScreenBackground())
        .navigationTitle("Connection Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
private struct DebugSettingsSheet: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Use Android Emulator", isOn: $store.debugSettings.useAndroidEmulator)

                    LabeledContent("Host") {
                        TextField("127.0.0.1", text: $store.debugSettings.emulatorHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(debugFieldForegroundStyle)
                    }
                    .disabled(!store.debugSettings.useAndroidEmulator)
                    .foregroundStyle(debugFieldForegroundStyle)
                    .opacity(debugFieldOpacity)

                    LabeledContent("Port") {
                        TextField("5555", text: $store.debugSettings.emulatorPortInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .foregroundStyle(debugFieldForegroundStyle)
                    }
                    .disabled(!store.debugSettings.useAndroidEmulator)
                    .foregroundStyle(debugFieldForegroundStyle)
                    .opacity(debugFieldOpacity)
                } footer: {
                    Text("Uses real ADB after injecting a local emulator into discovery.")
                }
            }
            .navigationTitle("Android Emulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.send(.hideDebugSettings)
                    }
                }
            }
        }
    }

    private var debugFieldForegroundStyle: Color {
        store.debugSettings.useAndroidEmulator ? .primary : .secondary
    }

    private var debugFieldOpacity: Double {
        store.debugSettings.useAndroidEmulator ? 1 : 0.45
    }
}
#endif
