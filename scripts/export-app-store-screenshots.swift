#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

private struct TestAttachmentGroup: Decodable {
    let attachments: [Attachment]
}

private struct Attachment: Decodable {
    let exportedFileName: String
    let suggestedHumanReadableName: String
}

private enum ExportError: LocalizedError {
    case usage
    case missingManifest(URL)
    case missingAttachment(String)
    case unreadableImage(URL)
    case wrongDimensions(name: String, actual: String, expected: String)
    case alphaChannel(String)
    case wrongBitDepth(name: String, bits: Int)
    case failedToCreateOpaquePNG(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: export-app-store-screenshots.swift ATTACHMENTS OUTPUT WIDTH HEIGHT"
        case let .missingManifest(url):
            return "Attachment manifest not found at \(url.path)"
        case let .missingAttachment(name):
            return "Required screenshot attachment '\(name)' is missing"
        case let .unreadableImage(url):
            return "Could not decode PNG at \(url.path)"
        case let .wrongDimensions(name, actual, expected):
            return "\(name) is \(actual); expected \(expected)"
        case let .alphaChannel(name):
            return "\(name) contains an alpha channel"
        case let .wrongBitDepth(name, bits):
            return "\(name) uses \(bits)-bit components; expected 8-bit"
        case let .failedToCreateOpaquePNG(name):
            return "Could not flatten \(name) into an opaque sRGB PNG"
        }
    }
}

private let expectedNames = [
    "01-device",
    "02-files",
    "03-shell",
    "04-apps",
    "05-logs",
    "06-screens",
]

private func attachment(
    named expectedName: String,
    in groups: [TestAttachmentGroup]
) -> Attachment? {
    groups.lazy
        .flatMap(\.attachments)
        .first { attachment in
            let name = attachment.suggestedHumanReadableName
            return name == expectedName
                || name == "\(expectedName).png"
                || name.hasPrefix("\(expectedName)_")
        }
}

private func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
        return false
    case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
        return true
    @unknown default:
        return true
    }
}

private func validate(
    imageAt url: URL,
    name: String,
    expectedWidth: Int,
    expectedHeight: Int
) throws {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ExportError.unreadableImage(url)
    }

    guard image.width == expectedWidth, image.height == expectedHeight else {
        throw ExportError.wrongDimensions(
            name: name,
            actual: "\(image.width)×\(image.height)",
            expected: "\(expectedWidth)×\(expectedHeight)"
        )
    }
    guard !hasAlpha(image) else {
        throw ExportError.alphaChannel(name)
    }
    guard image.bitsPerComponent == 8 else {
        throw ExportError.wrongBitDepth(name: name, bits: image.bitsPerComponent)
    }
}

/// XCTest screenshots can carry an alpha channel even though every captured
/// screen pixel is opaque. Redrawing through an RGB context removes that
/// metadata and normalizes the App Store upload to 8-bit sRGB.
private func writeOpaquePNG(
    from sourceURL: URL,
    to destinationURL: URL,
    name: String,
    expectedWidth: Int,
    expectedHeight: Int
) throws {
    guard
        let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else {
        throw ExportError.failedToCreateOpaquePNG(name)
    }

    let hasExpectedDimensions = sourceImage.width == expectedWidth
        && sourceImage.height == expectedHeight
    let needsQuarterTurn = sourceImage.width == expectedHeight
        && sourceImage.height == expectedWidth
    guard hasExpectedDimensions || needsQuarterTurn else {
        throw ExportError.wrongDimensions(
            name: name,
            actual: "\(sourceImage.width)×\(sourceImage.height)",
            expected: "\(expectedWidth)×\(expectedHeight)"
        )
    }

    guard let context = CGContext(
            data: nil,
            width: expectedWidth,
            height: expectedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw ExportError.failedToCreateOpaquePNG(name)
    }

    context.interpolationQuality = .high
    if needsQuarterTurn {
        // XCUIScreen on iPad can encode landscape pixels in a portrait PNG.
        // Rotate clockwise so the status bar returns to the top edge.
        context.translateBy(x: CGFloat(expectedWidth), y: 0)
        context.rotate(by: .pi / 2)
    }
    context.draw(
        sourceImage,
        in: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
    )

    guard
        let opaqueImage = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        throw ExportError.failedToCreateOpaquePNG(name)
    }

    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ExportError.failedToCreateOpaquePNG(name)
    }
}

private func run() throws {
    guard CommandLine.arguments.count == 5,
          let expectedWidth = Int(CommandLine.arguments[3]),
          let expectedHeight = Int(CommandLine.arguments[4]) else {
        throw ExportError.usage
    }

    let fileManager = FileManager.default
    let attachmentsDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let manifestURL = attachmentsDirectory.appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
        throw ExportError.missingManifest(manifestURL)
    }

    let groups = try JSONDecoder().decode(
        [TestAttachmentGroup].self,
        from: Data(contentsOf: manifestURL)
    )

    let stagingDirectory = outputDirectory
        .deletingLastPathComponent()
        .appendingPathComponent(".\(outputDirectory.lastPathComponent).staging-\(ProcessInfo.processInfo.processIdentifier)")
    if fileManager.fileExists(atPath: stagingDirectory.path) {
        try fileManager.removeItem(at: stagingDirectory)
    }
    try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

    do {
        for expectedName in expectedNames {
            guard let match = attachment(named: expectedName, in: groups) else {
                throw ExportError.missingAttachment(expectedName)
            }

            let sourceURL = attachmentsDirectory.appendingPathComponent(match.exportedFileName)
            let destinationURL = stagingDirectory.appendingPathComponent("\(expectedName).png")
            try writeOpaquePNG(
                from: sourceURL,
                to: destinationURL,
                name: expectedName,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
            try validate(
                imageAt: destinationURL,
                name: expectedName,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }

        if fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.removeItem(at: outputDirectory)
        }
        try fileManager.moveItem(at: stagingDirectory, to: outputDirectory)
    } catch {
        try? fileManager.removeItem(at: stagingDirectory)
        throw error
    }

    print("Exported \(expectedNames.count) validated screenshots to \(outputDirectory.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
