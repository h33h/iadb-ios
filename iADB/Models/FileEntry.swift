import Foundation

/// Represents a file/directory on the Android device
struct FileEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let permissions: String
    let owner: String
    let group: String
    let size: String
    let date: String
    let time: String
    let isDirectory: Bool
    let isSymlink: Bool
    let symlinkTarget: String?
    let fullPath: String

    /// Android's `ls` does not expose whether a symlink target is a directory.
    /// Allow opening links optimistically; a link to a regular file remains
    /// available through its context actions if directory loading fails.
    var isNavigableDirectory: Bool { isDirectory || isSymlink }

}
