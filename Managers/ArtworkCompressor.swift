import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkCompressor {
    static let minBytesForCompression = 150_000
    static let maxDimension: CGFloat = 512
    static let jpegQuality: CGFloat = 0.8

    /// Returns data suitable for disk storage. Small images are kept as-is;
    /// large images are downsampled and re-encoded as JPEG when that reduces size.
    static func prepareForStorage(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard data.count > minBytesForCompression else { return data }
        return compress(data) ?? data
    }

    static func compress(_ data: Data) -> Data? {
        guard data.count > minBytesForCompression else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let result = output as Data
        return result.count < data.count ? result : nil
    }
}
