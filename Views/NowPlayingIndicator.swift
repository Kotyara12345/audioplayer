import Foundation
import SwiftUI

struct NowPlayingIndicator: View {
    let isPlaying: Bool
    var tint: Color = .accentColor

    var body: some View {
        Group {
            if isPlaying { EqualizerBars(tint: tint) }
            else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct EqualizerBars: View {
    let tint: Color
    private let barCount = 3
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 1.2
                    let freq = 2.5 + Double(i) * 0.8
                    let raw = (sin(t * freq + phase) + 1) / 2
                    let h = 4 + raw * (maxHeight - 4)
                    Capsule().fill(tint).frame(width: barWidth, height: h)
                }
            }
            .frame(height: maxHeight, alignment: .bottom)
        }
    }
}