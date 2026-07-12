import SwiftUI

struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private let licenses = [
        LicenseDocument(name: "Combine Schedulers", resource: "combine-schedulers-License"),
        LicenseDocument(name: "Swift Case Paths", resource: "swift-case-paths-License"),
        LicenseDocument(name: "Swift Clocks", resource: "swift-clocks-License"),
        LicenseDocument(name: "Swift Collections", resource: "swift-collections-License"),
        LicenseDocument(name: "The Composable Architecture", resource: "swift-composable-architecture-License"),
        LicenseDocument(name: "Swift Concurrency Extras", resource: "swift-concurrency-extras-License"),
        LicenseDocument(name: "Swift Custom Dump", resource: "swift-custom-dump-License"),
        LicenseDocument(name: "Swift Dependencies", resource: "swift-dependencies-License"),
        LicenseDocument(name: "Swift Identified Collections", resource: "swift-identified-collections-License"),
        LicenseDocument(name: "Swift Navigation", resource: "swift-navigation-License"),
        LicenseDocument(name: "Swift Perception", resource: "swift-perception-License"),
        LicenseDocument(name: "Swift Sharing", resource: "swift-sharing-License"),
        LicenseDocument(name: "Swift Syntax", resource: "swift-syntax-License"),
        LicenseDocument(name: "XCTest Dynamic Overlay", resource: "xctest-dynamic-overlay-License")
    ]

    var body: some View {
        NavigationStack {
            List(licenses) { license in
                NavigationLink(license.name) {
                    ScrollView {
                        Text(license.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(license.name)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .navigationTitle("Open Source Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct LicenseDocument: Identifiable {
    let name: String
    let resource: String
    var id: String { resource }

    var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text is unavailable."
        }
        return text
    }
}
