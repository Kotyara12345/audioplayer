import SwiftUI

struct NowPlayingFullScreen: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false

    init() {}

    var body: some View {
        GeometryReader { proxy in
            let artworkSide = max(
                120,
                min(proxy.size.width - 64, proxy.size.height * 0.46)
            )

            VStack(spacing: 20) {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                ArtworkView(
                    artworkID: player.currentTrack?.artworkID,
                    size: artworkSide,
                    cornerRadius: 20
                )
                .shadow(radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(player.currentTrack?.artist.isEmpty == false
                         ? player.currentTrack?.artist ?? ""
                         : loc.localized("player.unknown_artist"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = player.currentTrack?.album, !album.isEmpty {
                        Text(album)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal)

                ProgressBarView()
                    .padding(.horizontal)

                HStack(spacing: 32) {
                    Button {
                        player.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 22))
                            .foregroundStyle(player.isShuffled
                                             ? Color.accentColor : .secondary)
                    }
                    .accessibilityLabel(loc.localized("player.shuffle"))

                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                    }
                    .accessibilityLabel(loc.localized("player.previous"))

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying
                              ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                    }
                    .disabled(player.currentTrack == nil)
                    .accessibilityLabel(
                        player.isPlaying
                            ? loc.localized("player.pause")
                            : loc.localized("player.play")
                    )

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                    }
                    .disabled(!player.hasNext && player.repeatMode != .all)
                    .accessibilityLabel(loc.localized("player.next"))

                    Button {
                        player.cycleRepeatMode()
                    } label: {
                        Image(systemName: player.repeatMode.systemImage)
                            .font(.system(size: 22))
                            .foregroundStyle(player.repeatMode.isActive
                                             ? Color.accentColor : .secondary)
                    }
                    .accessibilityLabel(loc.localized("player.repeat"))
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(12)
            }
            .padding(8)
            .accessibilityLabel(loc.localized("action.close"))
        }
        .overlay(alignment: .topLeading) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(12)
            }
            .padding(8)
            .accessibilityLabel(loc.localized("queue.title"))
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }
}
