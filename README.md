# MusicPlayer

A local, offline music player for iPhone built with SwiftUI and the Swift 6
language mode.

## Requirements

- macOS with Xcode 27 (Swift 6.4.1, iOS 27 SDK)
- iOS 17.0 or later on the target device or simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Generate and build

`MusicPlayer.xcodeproj` is not checked in. Generate it from `project.yml`:

```sh
brew install xcodegen
xcodegen generate
open MusicPlayer.xcodeproj
```

The generated scheme is `MusicPlayer`. Set a development team in Xcode before
running on a physical device.

Command-line build and tests:

```sh
# See the destinations and simulators installed for this Xcode.
xcodebuild -project MusicPlayer.xcodeproj -scheme MusicPlayer -showdestinations

# Replace the destination with one listed by the command above.
xcodebuild test \
  -project MusicPlayer.xcodeproj \
  -scheme MusicPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Tests use Swift Testing and a host application because they exercise the app's
module and main-actor playback queue.

## Features

- Folder-based library import through the system document picker
- Songs, albums, and artists views with search and recent tracks
- Play/pause, previous/next, seeking, queue editing, shuffle, repeat, and sleep
  timer
- Now Playing and lock-screen remote commands
- Hidden-track state persisted between launches
- Background library refresh with `BGProcessingTask`
- English and Russian localization
- Artwork thumbnails with downsampling and an in-memory cost limit

The selected folder is stored as a security-scoped bookmark. Folders inside the
app container are also supported. No account, network service, analytics, or
tracking is used.

## Architecture

- `MusicLibraryManager` scans a folder off the main actor, streams batches to the
  UI, and treats the final scan as authoritative. A generation token prevents a
  canceled or superseded scan from publishing stale results. A failed or
  interrupted scan restores the pre-scan snapshot instead of keeping partial
  batches.
- `MetadataCache` stores metadata only, never artwork blobs. Loads and writes run
  through a background actor; artwork lives in `ArtworkStore`.
- `ArtworkImageCache` deduplicates in-flight thumbnail loads, downsamples images,
  and accounts for their approximate memory cost.
- `PlayerEngine` is main-actor isolated and uses injectable
  `AudioPlayerProtocol` / `AudioSessionControlling` implementations. It owns the
  queue, repeat/shuffle behavior, Now Playing metadata, remote commands, and the
  sleep timer.
- `BackgroundScanCoordinator` registers the background processing task, waits for
  bookmark restoration on cold launch, and cancels the active scan when the
  system expires the task.

## Notes and limitations

- iCloud files that are not downloaded are shown with a cloud icon but are never
  opened by the player or scanned for metadata. Download status is checked again
  immediately before playback, so an evicted file cannot trigger an implicit
  download.
- Gapless playback is not implemented. `AVAudioPlayer` is used for predictable
  local playback and seeking; the player protocol leaves room for another
  backend.
- Metadata loading and folder enumeration run off the main actor. Creating and
  controlling `AVAudioPlayer` still happens on the main actor.
- Background refresh is discretionary. iOS decides when (and whether) a
  `BGProcessingTask` runs.
- The app icon PNGs in
  `Resources/Assets.xcassets/AppIcon.appiconset` are placeholders. Replace them
  with final artwork before shipping.
- `Resources/Info.plist` is the source of truth for the app's configuration. The
  XcodeGen spec deliberately has no `info:` block, so `xcodegen generate` does
  not overwrite it. The plist contains an empty `UILaunchScreen` dictionary and
  the SwiftUI scene manifest required by the iOS 27 SDK.
- `Resources/PrivacyInfo.xcprivacy` covers the app's `UserDefaults` and file
  timestamp access. Update it if you add APIs that require additional declarations.
