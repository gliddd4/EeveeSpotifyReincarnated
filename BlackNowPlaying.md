# BlackNowPlaying

All-black Now Playing UI: renders an all-black gradient background for album
covers that are mostly black (the "donda / 25% black album" use case), instead
of the stock artwork-backed gradient.

## Implementation (this branch)

The feature implementation is squashed into `6602338` (along with the canvas
work and the lyric refactor), then refined on top of this branch:

- `Sources/EeveeSpotify/BlackNowPlayingUI.x.swift`
  - `activateBlackNowPlayingUI()`, toggle-read at activation.
  - `shouldForceBlackGradient()` — mostly-black detection: the cover's primary
    color (Gaussian-blurred then reduced to a 1x1 `CIAreaAverage`) is judged
    by relative luminance, OR'd with the 25%-black pixel ratio; cached
    per-URI to avoid repeated histogram/blur work and stale hits on
    Donda-style covers.
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

### Refinements applied on this branch (cherry-picked from Master-impl)

- `2dd6bc8` — `9ea68f5` "Lower black-cover threshold to 50%→25% and fix URI
  cache stale-hit on Donda": threshold 0.5 → 0.25, plus fall back to the live
  player-track URI when the viewWillAppear capture didn't fire, so the cache
  key stays unique (the stale-hit was making every album render black).
- `f21fcdc` — the NSURL URI cast from `c8321ab`/`stash@{0}`: cast `URI()`
  through `NSURL` before reading `absoluteString`, guarding against a
  type-mismatch crash on rewritten local-track URIs. This fix was missing from
  Master-impl's tip (`9ea68f5` still used the unguarded form).

## Research findings (Aug 5 2026 subagent)

- The feature is NOT on the local `Master` branch (no `BlackNowPlayingUI.x.swift`,
  no settings key, no strings, no Tweak.x activation). It lives only on this
  branch and `Master-impl`.
- `origin/Master` (7662f88) looked like it had the feature, but that was a
  **stale local ref** — `origin` and `myfork` point at the same GitHub repo,
  whose live Master is the current Master branch without BNP.
- Three versions exist: BlackNowPlaying branch (0.5 threshold, no cast),
  Master-impl tip `9ea68f5` (0.25 + live-URI fallback, no cast), and the final
  `c8321ab` stash blob (0.25 + live-URI fallback + NSURL cast). This branch
  now carries the final form.
- **String drift**: fixed on this branch — the description now says "mostly
  black" (previously claimed "at least 50% black" while the threshold was
  25%).
- Porting to Master requires an additive edit to
  `V91TrackMetadataCapture.x.swift` (add `capturedTrackURI` + a
  diagnostics-stripped `captureCanvasTrack(_:)`) — do NOT copy Master-impl's
  V91 file wholesale, it deletes the metadata cache Master's lyrics pipeline
  still uses. Other deps present on Master: `statefulPlayer`, `writeDebugLog`,
  `NPVScrollViewController` (V1), `SPTPlayerTrack.URI()`.

## Status

Feature works on this branch (25% threshold + URI cast). Verified build clean.
Known limitation from device testing: the "is this album black" detection
previously rendered every album black — that was the stale-hit fixed by
`2dd6bc8`; needs a fresh device test to confirm.
