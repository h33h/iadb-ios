import Foundation
import XCTest
@testable import iADB

final class FileEntryTests: XCTestCase {

    // MARK: - Parsing ls -la output

    func testParseRegularFile() {
        let line = "-rw-rw-r-- 1 root sdcard_rw 12345 2024-01-15 10:30 photo.jpg"
        let entry = FileEntry.parse(line: line, parentPath: "/sdcard")

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "photo.jpg")
        XCTAssertEqual(entry?.permissions, "-rw-rw-r--")
        XCTAssertEqual(entry?.owner, "root")
        XCTAssertEqual(entry?.group, "sdcard_rw")
        XCTAssertEqual(entry?.size, "12345")
        XCTAssertEqual(entry?.date, "2024-01-15")
        XCTAssertEqual(entry?.time, "10:30")
        XCTAssertFalse(entry!.isDirectory)
        XCTAssertFalse(entry!.isSymlink)
        XCTAssertNil(entry?.symlinkTarget)
        XCTAssertEqual(entry?.fullPath, "/sdcard/photo.jpg")
    }

    func testParseDirectory() {
        let line = "drwxrwx--x 3 root sdcard_rw 4096 2024-03-20 08:00 Download"
        let entry = FileEntry.parse(line: line, parentPath: "/sdcard")

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "Download")
        XCTAssertTrue(entry!.isDirectory)
        XCTAssertFalse(entry!.isSymlink)
        XCTAssertEqual(entry?.fullPath, "/sdcard/Download")
    }

    func testParseSymlink() {
        let line = "lrwxrwxrwx 1 root root 15 2024-01-01 00:00 link -> /data/actual"
        let entry = FileEntry.parse(line: line, parentPath: "/")

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "link")
        XCTAssertTrue(entry!.isSymlink)
        XCTAssertEqual(entry?.symlinkTarget, "/data/actual")
    }

    func testParseDotEntryIsIgnored() {
        let line = "drwxr-xr-x 5 root root 4096 2024-01-01 00:00 ."
        XCTAssertNil(FileEntry.parse(line: line, parentPath: "/sdcard"))
    }

    func testParseDotDotEntryIsIgnored() {
        let line = "drwxr-xr-x 5 root root 4096 2024-01-01 00:00 .."
        XCTAssertNil(FileEntry.parse(line: line, parentPath: "/sdcard"))
    }

    func testParseTotalLineIsIgnored() {
        XCTAssertNil(FileEntry.parse(line: "total 48", parentPath: "/sdcard"))
    }

    func testParseEmptyLineIsIgnored() {
        XCTAssertNil(FileEntry.parse(line: "", parentPath: "/sdcard"))
        XCTAssertNil(FileEntry.parse(line: "   ", parentPath: "/sdcard"))
    }

    func testParseTooFewFieldsIsIgnored() {
        XCTAssertNil(FileEntry.parse(line: "drwx root", parentPath: "/sdcard"))
    }

    func testParseWithoutSize() {
        // Some ls implementations omit size for directories
        let line = "drwxrwx--x 3 root sdcard_rw 2024-03-20 08:00 DCIM"
        let entry = FileEntry.parse(line: line, parentPath: "/sdcard")

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "DCIM")
        XCTAssertTrue(entry!.isDirectory)
    }

    func testParseTrailingSlashOnParent() {
        let line = "-rw-r--r-- 1 root root 100 2024-01-01 00:00 file.txt"
        let entry = FileEntry.parse(line: line, parentPath: "/sdcard/")

        XCTAssertEqual(entry?.fullPath, "/sdcard/file.txt")
    }

    // MARK: - Display Size

    func testDisplaySizeBytes() {
        let entry = makeEntry(size: "500")
        XCTAssertEqual(entry.displaySize, "500 B")
    }

    func testDisplaySizeKB() {
        let entry = makeEntry(size: "2048")
        XCTAssertEqual(entry.displaySize, "2.0 KB")
    }

    func testDisplaySizeMB() {
        let entry = makeEntry(size: "5242880")
        XCTAssertEqual(entry.displaySize, "5.0 MB")
    }

    func testDisplaySizeGB() {
        let entry = makeEntry(size: "2147483648")
        XCTAssertEqual(entry.displaySize, "2.0 GB")
    }

    func testDisplaySizeNonNumeric() {
        let entry = makeEntry(size: "unknown")
        XCTAssertEqual(entry.displaySize, "unknown")
    }

    func testDisplaySizeEmpty() {
        let entry = makeEntry(size: "")
        XCTAssertEqual(entry.displaySize, "")
    }

    // MARK: - Icon Name

    func testIconDirectory() {
        XCTAssertEqual(makeEntry(name: "dir", isDir: true).iconName, "folder.fill")
    }

    func testIconSymlink() {
        XCTAssertEqual(makeEntry(name: "link", isSymlink: true).iconName, "link")
    }

    func testIconAPK() {
        XCTAssertEqual(makeEntry(name: "app.apk").iconName, "app.badge")
    }

    func testIconImage() {
        XCTAssertEqual(makeEntry(name: "photo.jpg").iconName, "photo")
        XCTAssertEqual(makeEntry(name: "image.png").iconName, "photo")
        XCTAssertEqual(makeEntry(name: "pic.webp").iconName, "photo")
    }

    func testIconVideo() {
        XCTAssertEqual(makeEntry(name: "video.mp4").iconName, "film")
        XCTAssertEqual(makeEntry(name: "movie.mkv").iconName, "film")
    }

    func testIconAudio() {
        XCTAssertEqual(makeEntry(name: "song.mp3").iconName, "music.note")
        XCTAssertEqual(makeEntry(name: "audio.flac").iconName, "music.note")
    }

    func testIconText() {
        XCTAssertEqual(makeEntry(name: "readme.txt").iconName, "doc.text")
        XCTAssertEqual(makeEntry(name: "app.log").iconName, "doc.text")
    }

    func testIconCode() {
        XCTAssertEqual(makeEntry(name: "data.json").iconName, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(makeEntry(name: "layout.xml").iconName, "chevron.left.forwardslash.chevron.right")
    }

    func testIconArchive() {
        XCTAssertEqual(makeEntry(name: "backup.zip").iconName, "doc.zipper")
        XCTAssertEqual(makeEntry(name: "files.tar").iconName, "doc.zipper")
    }

    func testIconPDF() {
        XCTAssertEqual(makeEntry(name: "doc.pdf").iconName, "doc.richtext")
    }

    func testIconShell() {
        XCTAssertEqual(makeEntry(name: "run.sh").iconName, "terminal")
    }

    func testIconLibrary() {
        XCTAssertEqual(makeEntry(name: "lib.so").iconName, "puzzlepiece")
    }

    func testIconDatabase() {
        XCTAssertEqual(makeEntry(name: "data.db").iconName, "cylinder")
    }

    func testIconUnknown() {
        XCTAssertEqual(makeEntry(name: "file.xyz").iconName, "doc")
    }

    // MARK: - Helpers

    private func makeEntry(
        name: String = "file",
        size: String = "0",
        isDir: Bool = false,
        isSymlink: Bool = false
    ) -> FileEntry {
        FileEntry(
            name: name,
            permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--",
            owner: "root",
            group: "root",
            size: size,
            date: "2024-01-01",
            time: "00:00",
            isDirectory: isDir,
            isSymlink: isSymlink,
            symlinkTarget: nil,
            fullPath: "/\(name)"
        )
    }
}
