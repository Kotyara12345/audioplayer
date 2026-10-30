import UIKit

@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private var inFlight: [String: Task<SendableImage?, Never>] = [:]

    init() {}

    func image(
        for artworkID: String,
        maxPixel: CGFloat,
        store: ArtworkStore = .shared
    ) async -> UIImage? {
        let requestedPixel = maxPixel.isFinite ? maxPixel : 512
        let boundedPixel = min(max(requestedPixel, 1), 4_096)
        let pixelSize = Int(boundedPixel.rounded(.up))
        let key = "\(artworkID)#\(pixelSize)"

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value?.image
        }

        let task = Task {
            await store.image(for: artworkID, maxPixel: CGFloat(pixelSize))
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let image = result?.image else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        return image
    }

    private static func cost(of image: UIImage) -> Int {
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        return max(1, width * height * 4)
    }
}
