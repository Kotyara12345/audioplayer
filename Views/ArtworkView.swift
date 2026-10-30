import SwiftUI
import UIKit

struct ArtworkView: View {
    let artworkID: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    init(artworkID: String?, size: CGFloat, cornerRadius: CGFloat = 8) {
        self.artworkID = artworkID
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.16),
                        Color.purple.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: max(12, size * 0.28)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: artworkID) {
            guard let artworkID else {
                image = nil
                return
            }
            image = nil
            let maxPixel = size * displayScale
            let loaded = await ArtworkImageCache.shared.image(
                for: artworkID,
                maxPixel: maxPixel
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
