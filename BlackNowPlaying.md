# BlackNowPlaying

All-black Now Playing UI: renders an all-black gradient background for album
covers that are mostly black (the "donda / 25% black album" use case), instead
of the stock artwork-backed gradient.

## What's embedded in main

The feature is already merged into the main branch (tested build). Related code:

- `Sources/EeveeSpotify/BlackNowPlayingUI.x.swift`
  - `activateBlackNowPlayingUI()` (~line 109), toggle-read at activation.
  - `shouldForceBlackGradient()` — mostly-black detection using the 25% black
    threshold plus a per-URI cached hit/miss (avoids repeated histogram work
    and fixes a stale-hit on Donda-style covers).
  - Reads `capturedTrackURI` (set by the canvas `captureCanvasTrack(_:)` hook in
    `V91TrackMetadataCapture.x.swift`) as the primary cache key.
- `Sources/EeveeSpotify/Tweak.x.swift` — activation lines 527 (9.1.68 path) and
  541 (generic path).
- `Sources/EeveeSpotify/Settings/Sections/UI/Views/EeveeUISettingsView.swift` —
  settings toggle.
- `Sources/EeveeSpotify/Shared/Models/Extensions/UserDefaults+Extension.swift` —
  `blackNowPlayingUIKey`.
- `layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings` —
  `black_now_playing_ui` + description strings.

## Research notes / deltas not in main

Because this branch diverges from the latest changes, the following refinements
live as notes instead of commits (fold in only after re-checking against main):

- `Master-impl` commit `9ea68f5` "Lower black-cover threshold to 50%→25% and fix
  URI cache stale-hit on Donda" — 8 insertions, 2 deletions in
  `BlackNowPlayingUI.x.swift` only.
- `Master-impl` commit `c8321ab` (+ `stash@{0}`) — BlackNowPlayingUI URI cast:
  cast `URI()` result through `NSURL` before reading `absoluteString`. (The
  stash also touched `.gitignore`; our `.gitignore` changes are never
  committed.)

## Status

Feature active and shipping in main. The two `Master-impl` refinements
(25% threshold + URI cast) are pending manual verification against main.
