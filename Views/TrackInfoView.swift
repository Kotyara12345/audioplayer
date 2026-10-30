import Foundation
import SwiftUI

struct TrackInfoView: View {
    let track: Track
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    init(track: Track) {
        self.track = track
    }

    var body: some View {
        NavigationStack {
            List {
                if track.artworkID != nil {
                    Section {
                        HStack {
                            Spacer()
                            ArtworkView(
                                artworkID: track.artworkID,
                                size: 200,
                                cornerRadius: 12
                            )
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                Section(loc.localized("info.section.metadata")) {
                    row(loc.localized("info.track_title"), track.title)
                    row(
                        loc.localized("info.artist"),
                        track.artist.isEmpty
                            ? loc.localized("player.unknown_artist")
                            : track.artist
                    )
                    row(
                        loc.localized("info.album"),
                        track.album.isEmpty
                            ? loc.localized("player.unknown_album")
                            : track.album
                    )
                    if !track.albumArtist.isEmpty {
                        row(loc.localized("info.album_artist"), track.albumArtist)
                    }
                    if let discNumber = track.discNumber {
                        row(loc.localized("info.disc_number"), "\(discNumber)")
                    }
                    if let trackNumber = track.trackNumber {
                        row(loc.localized("info.track_number"), "\(trackNumber)")
                    }
                    row(loc.localized("info.duration"), formatDuration(track.duration))
                    if track.isCloudOnly {
                        row(
                            loc.localized("info.icloud"),
                            loc.localized("track.cloud_only")
                        )
                    }
                }

                Section(loc.localized("info.section.file")) {
                    row(loc.localized("info.file_path"), track.url.lastPathComponent)
                    if let values = try? track.url.resourceValues(
                        forKeys: [
                            .fileSizeKey,
                            .contentModificationDateKey,
                            .typeIdentifierKey
                        ]
                    ) {
                        if let size = values.fileSize {
                            row(
                                loc.localized("info.file_size"),
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(size),
                                    countStyle: .file
                                )
                            )
                        }
                        if let date = values.contentModificationDate {
                            row(
                                loc.localized("info.mod_date"),
                                date.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        if let type = values.typeIdentifier {
                            row(loc.localized("info.format"), type)
                        }
                    }
                }
            }
            .navigationTitle(Text(loc.localized("info.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.localized("action.done")) { dismiss() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formatDuration(_ time: TimeInterval) -> String {
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
