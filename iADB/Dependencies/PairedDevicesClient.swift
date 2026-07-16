import ComposableArchitecture
import Foundation

struct PairedDevicesClient: Sendable {
    var load: @Sendable () throws -> [PairedDevice]
    var save: @Sendable ([PairedDevice]) throws -> Void
    var reset: @Sendable () throws -> Void
}

private struct PairedDevicesFileStore: Sendable {
    let fileURL: URL

    func load() throws -> [PairedDevice] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([PairedDevice].self, from: Data(contentsOf: fileURL))
    }

    func save(_ devices: [PairedDevice]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(devices).write(to: fileURL, options: .atomic)
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

extension PairedDevicesClient: DependencyKey {
    static var liveValue: Self {
        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iADB/paired-devices.json")
        let store = PairedDevicesFileStore(fileURL: fileURL)
        return Self(
            load: { try store.load() },
            save: { try store.save($0) },
            reset: { try store.reset() }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("PairedDevicesClient.load", placeholder: []),
            save: unimplemented("PairedDevicesClient.save"),
            reset: unimplemented("PairedDevicesClient.reset")
        )
    }
}

extension DependencyValues {
    var pairedDevicesClient: PairedDevicesClient {
        get { self[PairedDevicesClient.self] }
        set { self[PairedDevicesClient.self] = newValue }
    }
}
