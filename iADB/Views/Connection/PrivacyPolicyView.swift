import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Data collection") {
                    Text(
                        "iADB has no accounts, advertising, analytics, or developer-operated servers. "
                            + "The developer does not receive your personal data, Android device data, "
                            + "commands, files, logs, or screenshots."
                    )
                }

                Section("Local network") {
                    Text(
                        "iADB connects from your iPhone or iPad to the Android device you select on the same "
                            + "local network. The app uses that connection to run the actions you request."
                    )
                }

                Section("Data stored on this device") {
                    Text(
                        "iADB stores paired-device identifiers and recent addresses, Shell history and pins, "
                            + "Logcat filters and presets, and screenshots you keep inside the app's container. "
                            + "The RSA identity used for ADB authentication is stored in iOS Keychain. Its private "
                            + "key stays on this device; Android receives only the public identity needed to pair."
                    )
                }

                Section("Photos") {
                    Text(
                        "iADB asks for add-only Photos access when you choose Save to Photos. The app cannot "
                            + "browse your photo library through this permission."
                    )
                }

                Section("Deleting data") {
                    Text(
                        "Use Forget for one saved Android device, or Reset ADB Identity in Settings to remove the "
                            + "Keychain identity and every saved device before deleting iADB. Clear Shell history, "
                            + "Logcat presets, and saved screenshots from their screens. Deleting iADB removes its "
                            + "app-container data, but the Keychain identity may otherwise remain. Remove iADB from "
                            + "Android's Wireless debugging paired devices to revoke trust there."
                    )
                }

                Section("Third-party code") {
                    Text(
                        "iADB includes open-source Swift libraries listed under Open Source Licenses. The app "
                            + "does not include advertising or analytics SDKs."
                    )
                }

                Section("Support") {
                    if let supportURL = URL(string: "https://github.com/h33h/iadb-ios/issues") {
                        Link("Report a privacy or support issue", destination: supportURL)
                    }
                    Text("Policy updated July 12, 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
