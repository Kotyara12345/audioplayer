import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Immutable image returned across the `ArtworkStore` actor boundary.
/// `UIImage` is safe to use after construction; it is only read on the main actor.
struct SendableImage: @unchecked Sendable {
    let image: UIImage
}

actor ArtworkStore {
    static let shared = ArtworkStore()

    private let directory: URL
    private let fileExtension = "img"

    init(directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicPlayer", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
        self.directory = baseDirectory
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

    func store(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let identifier = Self.identifier(for: data)
        let url = fileURL(for: identifier)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return identifier
        }
        do {
            try data.write(to: url, options: .atomic)
            return identifier
        } catch {
            return nil
        }
    }

    func existingIDs() -> Set<String> {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(
            urls
                .filter { $0.pathExtension == fileExtension }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    func image(for identifier: String, maxPixel: CGFloat) -> SendableImage? {
        let url = fileURL(for: identifier)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let requestedPixel = maxPixel.isFinite ? maxPixel : 512
        let boundedPixel = min(max(requestedPixel, 1), 4_096)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(boundedPixel.rounded(.up))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return SendableImage(image: UIImage(cgImage: image))
    }

    func data(for identifier: String) -> Data? {
        try? Data(contentsOf: fileURL(for: identifier))
    }

    func prune(keeping identifiers: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where url.pathExtension == fileExtension {
            let identifier = url.deletingPathExtension().lastPathComponent
            if !identifiers.contains(identifier) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for identifier: String) -> URL {
        directory
            .appendingPathComponent(identifier)
            .appendingPathExtension(fileExtension)
    }

    private static func identifier(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
