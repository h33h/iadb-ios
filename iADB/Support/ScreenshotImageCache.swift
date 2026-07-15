import UIKit

/// Bounds decoded screenshot memory and prevents SwiftUI body recomputation
/// from decoding the same PNG repeatedly. The source PNG remains owned by the
/// screenshot feature and is still the persistence source of truth.
@MainActor
final class ScreenshotImageCache {
    static let shared = ScreenshotImageCache()

    private let cache = NSCache<NSUUID, UIImage>()

    init(countLimit: Int = 60, totalCostLimit: Int = 128 * 1024 * 1024) {
        cache.countLimit = max(1, countLimit)
        cache.totalCostLimit = max(1, totalCostLimit)
    }

    func image(for entry: ScreenshotFeature.ScreenshotEntry) -> UIImage? {
        let key = entry.id as NSUUID
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: entry.data) else { return nil }
        cache.setObject(
            image,
            forKey: key,
            cost: max(decodedByteCost(of: image), entry.byteCount, entry.data.count)
        )
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func decodedByteCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }

        let pixelWidth = Int((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int((image.size.height * image.scale).rounded(.up))
        return pixelWidth * pixelHeight * 4
    }
}
