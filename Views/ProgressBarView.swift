import Foundation
import SwiftUI

struct ProgressBarView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .disabled(player.duration == 0)
            .accessibilityLabel(loc.localized("player.progress"))
            .accessibilityValue(
                "\(format(player.currentTime)) / \(format(player.duration))"
            )

            HStack {
                Text(format(player.currentTime))
                Spacer()
                Text(format(player.duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
