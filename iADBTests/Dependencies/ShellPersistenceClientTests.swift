import Foundation
import Testing
@testable import iADB

struct ShellPersistenceClientTests {
    private struct V2State: Codable {
        var version: Int
        var history: [V2Entry]
        var pinnedCommands: [DeviceScopedPinnedCommand]
        var draftsByDeviceID: [String: String]
    }

    private struct V2Entry: Codable {
        var id: UUID
        var command: String
        var output: String
        var timestamp: Date
        var isError: Bool
        var originDeviceID: String
    }

    private struct LegacyState: Codable {
        var history: [LegacyEntry]
        var pinnedCommands: [String]
    }

    private struct LegacyEntry: Codable {
        var id: UUID
        var command: String
        var output: String
        var timestamp: Date
        var isError: Bool
    }

    @Test
    func v1MigrationPreservesEntriesWithUnknownOrigin() throws {
        let id = UUID()
        let legacy = LegacyState(
            history: [LegacyEntry(
                id: id,
                command: "getprop",
                output: "Pixel",
                timestamp: Date(timeIntervalSince1970: 10),
                isError: false
            )],
            pinnedCommands: ["df -h"]
        )

        let migrated = try ShellPersistenceState.decodeMigrating(
            JSONEncoder().encode(legacy)
        )

        #expect(migrated.wasLegacy)
        #expect(migrated.state.version == ShellPersistenceState.currentVersion)
        #expect(migrated.state.history.first?.id == id)
        #expect(migrated.state.history.first?.originDeviceID == DeviceIdentity.unknownID)
        #expect(migrated.state.pinnedCommands.first?.originDeviceID == DeviceIdentity.unknownID)
        #expect(migrated.state.pinnedCommands.first?.command == "df -h")
    }

    @Test
    func fileMigrationAtomicallyWritesCurrentSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-shell-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("shell-history.json")
        let legacy = LegacyState(
            history: [],
            pinnedCommands: ["logcat -d"]
        )
        try JSONEncoder().encode(legacy).write(to: fileURL, options: .atomic)
        let store = ShellFileStore(
            directoryURL: root,
            legacyDefaults: nil,
            legacyDefaultsKey: "unused"
        )

        let loaded = store.load()
        let persisted = try JSONDecoder().decode(
            ShellPersistenceState.self,
            from: Data(contentsOf: fileURL)
        )

        #expect(loaded == persisted)
        #expect(persisted.version == ShellPersistenceState.currentVersion)
        #expect(persisted.pinnedCommands.first?.originDeviceID == DeviceIdentity.unknownID)
    }

    @Test
    func v2MigrationAddsStreamingMetadataWithoutLosingDeviceScope() throws {
        let id = UUID()
        let deviceID = "guid:pixel-9"
        let v2 = V2State(
            version: 2,
            history: [V2Entry(
                id: id,
                command: "getprop",
                output: "Pixel 9",
                timestamp: Date(timeIntervalSince1970: 20),
                isError: false,
                originDeviceID: deviceID
            )],
            pinnedCommands: [DeviceScopedPinnedCommand(
                command: "df -h",
                originDeviceID: deviceID
            )],
            draftsByDeviceID: [deviceID: "wm size"]
        )

        let migrated = try ShellPersistenceState.decodeMigrating(JSONEncoder().encode(v2))
        let entry = try #require(migrated.state.history.first)

        #expect(migrated.wasLegacy)
        #expect(migrated.state.version == ShellPersistenceState.currentVersion)
        #expect(entry.id == id)
        #expect(entry.originDeviceID == deviceID)
        #expect(entry.stdout == "Pixel 9")
        #expect(entry.stderr.isEmpty)
        #expect(entry.exitCode == nil)
        #expect(entry.duration == nil)
        #expect(entry.wasTruncated == false)
        #expect(migrated.state.pinnedCommands.first?.originDeviceID == deviceID)
        #expect(migrated.state.draftsByDeviceID[deviceID] == "wm size")
    }

    @Test
    func unreadableLegacyFileIsNotDeletedOrOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iadb-shell-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("shell-history.json")
        let original = Data("future-or-corrupt-schema".utf8)
        try original.write(to: fileURL)
        let store = ShellFileStore(
            directoryURL: root,
            legacyDefaults: nil,
            legacyDefaultsKey: "unused"
        )

        #expect(store.load() == .empty)
        #expect(try Data(contentsOf: fileURL) == original)
    }
}
