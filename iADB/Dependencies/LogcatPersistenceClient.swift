import Foundation
import ComposableArchitecture

struct LogcatPreset: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var filterText: String
    var level: LogEntry.LogLevel?

    init(id: UUID = UUID(), name: String, filterText: String, level: LogEntry.LogLevel?) {
        self.id = id
        self.name = name
        self.filterText = filterText
        self.level = level
    }
}

struct LogcatPersistenceState: Equatable, Codable {
    var filterText: String
    var selectedLevel: LogEntry.LogLevel?
    var presets: [LogcatPreset]

    static let maximumTextBytes = 4 * 1024
    static let maximumPresetCount = 50
    static let maximumBlobBytes = 256 * 1024

    static var empty: Self {
        Self(filterText: "", selectedLevel: nil, presets: [])
    }

    func sanitized() -> Self {
        var seenPresetIDs = Set<UUID>()
        var sanitizedPresets: [LogcatPreset] = []
        sanitizedPresets.reserveCapacity(min(presets.count, Self.maximumPresetCount))
        for preset in presets {
            guard sanitizedPresets.count < Self.maximumPresetCount else { break }
            guard seenPresetIDs.insert(preset.id).inserted else { continue }
            let name = Self.boundedText(preset.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            sanitizedPresets.append(LogcatPreset(
                id: preset.id,
                name: name,
                filterText: Self.boundedText(preset.filterText),
                level: preset.level
            ))
        }

        var result = Self(
            filterText: Self.boundedText(filterText),
            selectedLevel: selectedLevel,
            presets: sanitizedPresets
        )

        // Fifty presets at their individual limits can exceed the aggregate
        // persistence limit. Keep the newest prefix that fits the blob.
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

    static func decodedFromPersistence(_ data: Data) -> Self? {
        guard data.count <= maximumBlobBytes,
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        return decoded.sanitized()
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
                guard let data = defaults.value.data(forKey: key) else {
                    return .empty
                }

                guard let state = LogcatPersistenceState.decodedFromPersistence(data) else {
                    defaults.value.removeObject(forKey: key)
                    return .empty
                }

                if let sanitizedData = state.encodedForPersistence(), sanitizedData != data {
                    defaults.value.set(sanitizedData, forKey: key)
                }
                return state
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
