import Foundation
import SwiftUI
import UIKit

@MainActor
enum IconExporter {
    static let targetSize: CGFloat = 1024

    static func renderPNG(_ appearance: AppIconView.Appearance) -> Data? {
        let view = AppIconView(appearance: appearance, size: targetSize)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
        renderer.isOpaque = true
        guard let raw = renderer.uiImage else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1.0
        format.preferredRange = .standard
        let opaque = UIGraphicsImageRenderer(
            size: CGSize(width: targetSize, height: targetSize),
            format: format
        ).image { _ in
            raw.draw(in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        }
        return opaque.pngData()
    }

    static func exportAllToDocuments() throws -> [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var written: [URL] = []
        for appearance in AppIconView.Appearance.allCases {
            guard let data = renderPNG(appearance) else { throw AppError.cacheSaveFailed }
            let name = appearance == .light ? "AppIcon-Light.png" : "AppIcon-Dark.png"
            let url = docs.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }
}