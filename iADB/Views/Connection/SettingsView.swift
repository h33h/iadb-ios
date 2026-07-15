import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    @Bindable var store: StoreOf<ConnectionFeature>
    @Bindable var screenshotStore: StoreOf<ScreenshotFeature>
    var isEmbeddedInNavigationStack = false

    @State private var showingConnections = false
    @State private var showingPrivacyPolicy = false
    @State private var showingClearScreenshotsConfirmation = false

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
        Form {
            Section("Connection") {
                Button {
                    showingConnections = true
                } label: {
                    SettingsRow(
                        title: "Connections",
                        subtitle: "Current, nearby, saved and manual devices",
                        symbol: "network",
                        tint: .blue
                    )
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("settings.connections")
            }

            Section("Storage") {
                LabeledContent("Screenshot storage", value: screenshotStorageUsage)

                Button(role: .destructive) {
                    showingClearScreenshotsConfirmation = true
                } label: {
                    Text("Delete All Screenshots")
                }
                .disabled(screenshotStore.screenshots.isEmpty || screenshotStore.isClearing)
                .accessibilityIdentifier("settings.deleteAllScreenshots")

                Text("Captures remain available offline and include their origin device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
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
            } header: {
                Text("Privacy & Help")
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
        .contentMargins(.bottom, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(IADBScreenBackground())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingConnections) {
            ConnectionsFlowView(
                store: store,
                allowsDismissWhenConnected: true,
                startsDiscoveryOnAppear: false
            )
        }
        .onAppear { screenshotStore.send(.onAppear) }
        .sheet(isPresented: $showingPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .confirmationDialog(
            "Delete \(screenshotStore.screenshots.count) local screenshots?",
            isPresented: $showingClearScreenshotsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Local Screenshots", role: .destructive) {
                screenshotStore.send(.clearAll)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local gallery from this iPhone or iPad. It does not affect the Android device.")
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

    private var screenshotStorageUsage: String {
        if screenshotStore.isLoadingPersistence { return String(localized: "Loading…") }
        return ByteCountFormatter.string(
            fromByteCount: Int64(screenshotStore.storageByteCount),
            countStyle: .file
        )
    }
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        symbol: String,
        tint: Color
    ) {
        self.title = String(localized: title)
        self.subtitle = String(localized: subtitle)
        self.symbol = symbol
        self.tint = tint
    }

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
