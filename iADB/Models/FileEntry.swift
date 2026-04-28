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

    var displaySize: String {
        guard let bytes = Int64(size) else { return size }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0)) }
        return String(format: "%.1f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "link" }

        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "apk": return "app.badge"
        case "jpg", "jpeg", "png", "gif", "bmp", "webp": return "photo"
        case "mp4", "mkv", "avi", "mov": return "film"
        case "mp3", "wav", "ogg", "flac", "aac": return "music.note"
        case "txt", "log", "cfg", "conf", "ini": return "doc.text"
        case "xml", "json", "html", "css", "js": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "bz2", "7z": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "sh": return "terminal"
        case "so", "dylib": return "puzzlepiece"
        case "db", "sqlite": return "cylinder"
        default: return "doc"
        }
    }

    var isPreviewable: Bool {
        guard !isDirectory else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return [
            "txt", "log", "json", "xml", "yaml", "yml", "plist", "md", "csv", "ini", "conf", "cfg",
            "jpg", "jpeg", "png", "gif", "bmp", "webp"
        ].contains(ext)
    }

    /// Parse `ls -la` output line into a FileEntry
    static func parse(line: String, parentPath: String) -> FileEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("total") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 7 else { return nil }

        let perms = parts[0]
        let owner = parts[2]
        let group = parts[3]

        // Detect if size field is present or if it's a date
        var size = ""
        var dateStr = ""
        var timeStr = ""
        var nameStr = ""

        if parts.count >= 8 {
            size = parts[4]
            dateStr = parts[5]
            timeStr = parts[6]
            nameStr = parts[7]
        } else {
            dateStr = parts[4]
            timeStr = parts[5]
            nameStr = parts[6]
        }

        let isDir = perms.hasPrefix("d")
        let isLink = perms.hasPrefix("l")

        var fileName = nameStr
        var symlinkTarget: String? = nil

        if isLink, let arrowRange = nameStr.range(of: " -> ") {
            fileName = String(nameStr[nameStr.startIndex..<arrowRange.lowerBound])
            symlinkTarget = String(nameStr[arrowRange.upperBound...])
        }

        guard fileName != "." && fileName != ".." else { return nil }

        let fullPath = parentPath.hasSuffix("/") ? "\(parentPath)\(fileName)" : "\(parentPath)/\(fileName)"

        return FileEntry(
            name: fileName,
            permissions: perms,
            owner: owner,
            group: group,
            size: size,
            date: dateStr,
            time: timeStr,
            isDirectory: isDir,
            isSymlink: isLink,
            symlinkTarget: symlinkTarget,
            fullPath: fullPath
        )
    }
}
