import Foundation
import SwiftUI

struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.currentQueue.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(loc.localized("queue.empty"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(player.currentQueue.indices, id: \.self) { index in
                            queueRow(player.currentQueue[index], index: index)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Text(loc.localized("queue.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        player.clearUpcoming()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(player.upcomingTracks.isEmpty)
                    .accessibilityLabel(loc.localized("queue.clear_upcoming"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.localized("action.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func queueRow(_ track: Track, index: Int) -> some View {
        let isCurrent = index == player.currentQueueIndex
        Button {
            player.playFromQueue(at: index)
        } label: {
            HStack(spacing: 12) {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: player.isPlaying)
                } else {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }

                ArtworkView(artworkID: track.artworkID, size: 40, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(track.artist.isEmpty
                         ? loc.localized("player.unknown_artist") : track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if track.isCloudOnly {
                    Image(systemName: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(loc.localized("track.cloud_only"))
                }

                Text(formatTime(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isCurrent ? Color.accentColor.opacity(0.10) : Color.clear
        )
        .accessibilityLabel(
            "\(track.title), \(track.artist), \(formatTime(track.duration))"
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
