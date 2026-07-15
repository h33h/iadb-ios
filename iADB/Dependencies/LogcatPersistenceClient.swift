import Foundation
import ComposableArchitecture

struct LogcatPreset: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var filterText: String
    var level: LogEntry.LogLevel?
    var levels: Set<LogEntry.LogLevel>
    var originDeviceID: String
    var includedTags: Set<String>
    var excludedTerms: [String]
    var pid: Int?
    var isGlobal: Bool

    init(
        id: UUID = UUID(),
        name: String,
        filterText: String,
        level: LogEntry.LogLevel?,
        originDeviceID: String = DeviceIdentity.unknownID,
        includedTags: Set<String> = [],
        excludedTerms: [String] = [],
        pid: Int? = nil,
        isGlobal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.filterText = filterText
        self.level = level
        self.levels = level.map { [$0] } ?? []
        self.originDeviceID = originDeviceID
        self.includedTags = includedTags
        self.excludedTerms = excludedTerms
        self.pid = pid
        self.isGlobal = isGlobal
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, filterText, level, levels, originDeviceID
        case includedTags, excludedTerms, pid, isGlobal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        filterText = try container.decode(String.self, forKey: .filterText)
        level = try container.decodeIfPresent(LogEntry.LogLevel.self, forKey: .level)
        levels = try container.decodeIfPresent(Set<LogEntry.LogLevel>.self, forKey: .levels)
            ?? level.map { [$0] }
            ?? []
        originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
            ?? DeviceIdentity.unknownID
        includedTags = try container.decodeIfPresent(Set<String>.self, forKey: .includedTags) ?? []
        excludedTerms = try container.decodeIfPresent([String].self, forKey: .excludedTerms) ?? []
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        isGlobal = try container.decodeIfPresent(Bool.self, forKey: .isGlobal) ?? false
    }
}

struct LogcatFilter: Equatable, Codable {
    var levels: Set<LogEntry.LogLevel>
    var query: String
    var includedTags: Set<String>
    var excludedTerms: [String]
    var pid: Int?

    init(
        levels: Set<LogEntry.LogLevel> = [],
        query: String = "",
        includedTags: Set<String> = [],
        excludedTerms: [String] = [],
        pid: Int? = nil
    ) {
        self.levels = levels
        self.query = query
        self.includedTags = includedTags
        self.excludedTerms = excludedTerms
        self.pid = pid
    }

    init(filterText: String, selectedLevel: LogEntry.LogLevel?) {
        self.init(
            levels: selectedLevel.map { [$0] } ?? [],
            query: filterText
        )
    }

    var filterText: String {
        get { query }
        set { query = newValue }
    }

    var selectedLevel: LogEntry.LogLevel? {
        get { levels.count == 1 ? levels.first : nil }
        set { levels = newValue.map { [$0] } ?? [] }
    }

    static let empty = Self()

    private enum CodingKeys: String, CodingKey {
        case levels, query, includedTags, excludedTerms, pid
        case filterText, selectedLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyLevel = try container.decodeIfPresent(LogEntry.LogLevel.self, forKey: .selectedLevel)
        levels = try container.decodeIfPresent(Set<LogEntry.LogLevel>.self, forKey: .levels)
            ?? legacyLevel.map { [$0] }
            ?? []
        query = try container.decodeIfPresent(String.self, forKey: .query)
            ?? container.decodeIfPresent(String.self, forKey: .filterText)
            ?? ""
        includedTags = try container.decodeIfPresent(Set<String>.self, forKey: .includedTags) ?? []
        excludedTerms = try container.decodeIfPresent([String].self, forKey: .excludedTerms) ?? []
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(levels, forKey: .levels)
        try container.encode(query, forKey: .query)
        try container.encode(includedTags, forKey: .includedTags)
        try container.encode(excludedTerms, forKey: .excludedTerms)
        try container.encodeIfPresent(pid, forKey: .pid)
    }
}

typealias LogcatFilterSettings = LogcatFilter

struct LogcatPersistenceState: Equatable, Codable {
    static let currentVersion = 3

    var version: Int
    var filtersByDeviceID: [String: LogcatFilter]
    var presets: [LogcatPreset]

    static let maximumTextBytes = 4 * 1024
    static let maximumPresetCount = 50
    static let maximumBlobBytes = 256 * 1024

    init(
        version: Int = currentVersion,
        filtersByDeviceID: [String: LogcatFilter],
        presets: [LogcatPreset]
    ) {
        self.version = version
        self.filtersByDeviceID = filtersByDeviceID
        self.presets = presets
    }

    /// Source-compatible v1 initializer. Legacy filters and presets are kept
    /// under an explicit unknown origin and are never assigned to a real device.
    init(filterText: String, selectedLevel: LogEntry.LogLevel?, presets: [LogcatPreset]) {
        self.init(
            filtersByDeviceID: [
                DeviceIdentity.unknownID: LogcatFilter(
                    filterText: filterText,
                    selectedLevel: selectedLevel
                )
            ],
            presets: presets.map {
                LogcatPreset(
                    id: $0.id,
                    name: $0.name,
                    filterText: $0.filterText,
                    level: $0.level,
                    originDeviceID: $0.originDeviceID
                )
            }
        )
    }

    var filterText: String {
        get { filtersByDeviceID[DeviceIdentity.unknownID]?.filterText ?? "" }
        set {
            var settings = filtersByDeviceID[DeviceIdentity.unknownID] ?? .empty
            settings.filterText = newValue
            filtersByDeviceID[DeviceIdentity.unknownID] = settings
        }
    }

    var selectedLevel: LogEntry.LogLevel? {
        get { filtersByDeviceID[DeviceIdentity.unknownID]?.selectedLevel }
        set {
            var settings = filtersByDeviceID[DeviceIdentity.unknownID] ?? .empty
            settings.selectedLevel = newValue
            filtersByDeviceID[DeviceIdentity.unknownID] = settings
        }
    }

    static var empty: Self {
        Self(filtersByDeviceID: [:], presets: [])
    }

    func sanitized() -> Self {
        var sanitizedFilters: [String: LogcatFilter] = [:]
        for (rawDeviceID, settings) in filtersByDeviceID {
            let deviceID = rawDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceID.isEmpty else { continue }
            sanitizedFilters[deviceID] = LogcatFilter(
                levels: Set(settings.levels.filter { $0 != .silent && $0 != .unknown }),
                query: Self.boundedText(settings.query),
                includedTags: Set(settings.includedTags.map(Self.boundedText).filter { !$0.isEmpty }),
                excludedTerms: settings.excludedTerms.map(Self.boundedText).filter { !$0.isEmpty },
                pid: settings.pid
            )
        }

        var seenPresetIDs = Set<UUID>()
        var sanitizedPresets: [LogcatPreset] = []
        sanitizedPresets.reserveCapacity(min(presets.count, Self.maximumPresetCount))
        for preset in presets {
            guard sanitizedPresets.count < Self.maximumPresetCount else { break }
            guard seenPresetIDs.insert(preset.id).inserted else { continue }
            let name = Self.boundedText(preset.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let origin = preset.originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitizedPresets.append(LogcatPreset(
                id: preset.id,
                name: name,
                filterText: Self.boundedText(preset.filterText),
                level: preset.level,
                originDeviceID: origin.isEmpty ? DeviceIdentity.unknownID : origin,
                includedTags: Set(preset.includedTags.map(Self.boundedText).filter { !$0.isEmpty }),
                excludedTerms: preset.excludedTerms.map(Self.boundedText).filter { !$0.isEmpty },
                pid: preset.pid,
                isGlobal: preset.isGlobal
            ))
            sanitizedPresets[sanitizedPresets.index(before: sanitizedPresets.endIndex)].levels =
                Set(preset.levels.filter { $0 != .silent && $0 != .unknown })
        }

        var result = Self(filtersByDeviceID: sanitizedFilters, presets: sanitizedPresets)
        guard Self.encodedSize(of: result) > Self.maximumBlobBytes else {
            return result
        }

        var lowerBound = 0
        var upperBound = result.presets.count
        while lowerBound < upperBound {
            let candidateCount = (lowerBound + upperBound + 1) / 2
            var candidate = result
            candidate.presets = Array(result.presets.prefix(candidateCount))
            if Self.encodedSize(of: candidate) <= Self.maximumBlobBytes {
                lowerBound = candidateCount
            } else {
                upperBound = candidateCount - 1
            }
        }
        result.presets = Array(result.presets.prefix(lowerBound))
        return result
    }

    func encodedForPersistence() -> Data? {
        let state = sanitized()
        guard let data = try? JSONEncoder().encode(state),
              data.count <= Self.maximumBlobBytes else {
            return nil
        }
        return data
    }

    static func decodeMigrating(_ data: Data) -> (state: Self, wasLegacy: Bool)? {
        guard data.count <= maximumBlobBytes else { return nil }
        let decoder = JSONDecoder()
        if var decoded = try? decoder.decode(Self.self, from: data) {
            switch decoded.version {
            case currentVersion:
                return (decoded.sanitized(), false)
            case 2:
                decoded.version = currentVersion
                return (decoded.sanitized(), true)
            default:
                break
            }
        }

        struct Legacy: Codable {
            var filterText: String
            var selectedLevel: LogEntry.LogLevel?
            var presets: [LogcatPreset]
        }
        guard let legacy = try? decoder.decode(Legacy.self, from: data) else { return nil }
        return (
            Self(
                filterText: legacy.filterText,
                selectedLevel: legacy.selectedLevel,
                presets: legacy.presets
            ).sanitized(),
            true
        )
    }

    static func decodedFromPersistence(_ data: Data) -> Self? {
        decodeMigrating(data)?.state
    }

    static func boundedText(_ text: String) -> String {
        let utf8 = text.utf8
        guard let limitIndex = utf8.index(
            utf8.startIndex,
            offsetBy: maximumTextBytes,
            limitedBy: utf8.endIndex
        ), limitIndex != utf8.endIndex else {
            return text
        }
        var bytes = Array(utf8[..<limitIndex])
        while String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func encodedSize(of state: Self) -> Int {
        (try? JSONEncoder().encode(state).count) ?? .max
    }
}

struct LogcatPersistenceClient: Sendable {
    var load: @Sendable () -> LogcatPersistenceState
    var save: @Sendable (LogcatPersistenceState) -> Void
}

private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

extension LogcatPersistenceClient: DependencyKey {
    private static let key = "logcatPersistence"

    static var liveValue: Self {
        userDefaultsClient(defaults: .standard, key: key)
    }

    static func userDefaultsClient(defaults: UserDefaults, key: String) -> Self {
        let defaults = SendableUserDefaults(defaults)
        return Self(
            load: {
                guard let source = defaults.value.data(forKey: key) else {
                    return .empty
                }
                guard let decoded = LogcatPersistenceState.decodeMigrating(source) else {
                    // Recovery must not destroy data that a future app version or
                    // a user-assisted repair may still be able to understand.
                    return .empty
                }

                if let encoded = decoded.state.encodedForPersistence(),
                   decoded.wasLegacy || encoded != source {
                    defaults.value.set(encoded, forKey: key)
                    if defaults.value.data(forKey: key) != encoded {
                        defaults.value.set(source, forKey: key)
                    }
                }
                return decoded.state
            },
            save: { state in
                guard let data = state.encodedForPersistence() else { return }
                defaults.value.set(data, forKey: key)
            }
        )
    }

    static var previewValue: Self {
        Self(
            load: {
                LogcatPersistenceState(
                    filterText: "ActivityManager",
                    selectedLevel: .error,
                    presets: [LogcatPreset(name: "Errors", filterText: "", level: .error)]
                )
            },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("LogcatPersistenceClient.load", placeholder: .empty),
            save: unimplemented("LogcatPersistenceClient.save")
        )
    }
}

extension DependencyValues {
    var logcatPersistenceClient: LogcatPersistenceClient {
        get { self[LogcatPersistenceClient.self] }
        set { self[LogcatPersistenceClient.self] = newValue }
    }
}
