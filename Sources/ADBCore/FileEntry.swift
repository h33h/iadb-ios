import Foundation

/// Необработанные метаданные файла из ответа SYNC LIST_V2.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public let name: String
    public let fullPath: String
    public let mode: UInt32
    public let size: UInt64
    public let modificationDate: Date

    public var id: String { fullPath }
    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }

}
