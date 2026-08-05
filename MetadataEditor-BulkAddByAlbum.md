# MetadataEditor / BulkAddByAlbum

In-app metadata editor for local files — the backend needed for
`BulkAddAlbums` (bulk add local files to a playlist by album). Research-only
branch; diverges from the latest changes in main and carries only this
overview (matching the branch name).

## Why this exists

Album identity for local files is unreliable — the tags baked into the
`spotify:local:` URI at import time are what the UI shows. Bulk-add-by-album
needs correct album grouping, which requires editing the on-disk tags and
getting Spotify's cached view to refresh.

## How Spotify stores local files (verified seams, static dump of 9.1.68)

- Imported local files live in the app container's Documents folder.
- Every local track is addressable from its `spotify:local:...` URI, which
  embeds the parsed tags: `spotify:local:artist:album:title:duration`.
- `BetamaxOfflineSDK.OfflineManagerImpl`
  - `localFileURLForMediaURL:` — media URL -> on-disk file URL (the bridge)
  - `localFileSizeForMediaURL:` — confirms file exists + size
- `ListUXPlatform_FreeTierPlaylistImpl.FTPAllSongsDataSource` (Local Files list)
  - `trackURIForIndexPath:`, `albumNameForIndexPath:`, stable row/track ids
- `SPTMP3Demuxer` — read-only `readID3v2Size`/`id3v2Size` (MP3 only). No public
  tag WRITER in Spotify's headers.
- `SPTTagReader` — image/video tags only, not audio metadata.

## Editor pipeline

1. Enumerate Local Files list via `FTPAllSongsDataSource` -> URIs.
2. Resolve `localFileURLForMediaURL:` -> real file path.
3. Parse: MP3 = ID3v2 frames; M4A/AAC = MP4 atoms (`ilst`). Spotify has no
   public writer — need our own pure-Swift parser + writer.
4. Write tags in place, then refresh Spotify's cached view.

## The open problem — ANSWERED (Aug 5 2026 subagent)

The persistent store question is now largely settled (negatively):

- **No ObjC/Swift class persists local-file title/artist/album.** Every
  candidate was ruled out in the 9.1.68 dump:
  - `_TtC19LocalFiles_CoreImpl20LocalFilesAPIService` — SPTService whose only
    API is `provideLocalFilesSettingsModel` (enable/disable/permissionStatus).
    No metadata surface.
  - `_TtC28YourLibrary_YourLibraryXImpl34YourLibraryImportSyncControllerImp` —
    a Mobius UI-banner controller, not a metadata store.
  - `_TtC48LocalFiles_LocalFilesListConfigUpdateServiceImpl37...` +
    `Spotify_LocalFilesEsperanto_Proto_LocalFilesClient` — Esperanto (gRPC)
    clients with zero exposed methods; the endpoint is hosted by the core.
  - No sqlite/Core Data/DB-store classes for local files in the dump.
- **The real subsystem is C++ core code, invisible to class-dump:**
  `spotify::local_files::LocalFilesDelegate` (owned by
  `SPTCoreFullAuthenticatedScope._localFilesDelegate`, spotify_classes.txt:142452),
  `spotify::connect::LocalPlaybackView` (in
  `SPTLocalPlaybackViewImpl.localPlaybackView`), and `SPTLFMediaLibraryListener`
  (bridges `MPMediaLibrary` changes into a C++ `function<void()>` callback —
  the on-device re-scan trigger).
- **Strong hypothesis:** since the `spotify:local:` URI *embeds*
  artist/album/title/duration, the core can serve all list metadata by parsing
  the URI — there may be **no separate persistent metadata DB at all**; the
  URI string + the virtual-playlist item IS the "cache". That explains why
  editing the file never refreshes the UI. Unverified — needs a runtime probe
  (jailbroken device filesystem listing / Frida) to confirm.
- **Artwork is the exception:** `SPTLocalAVAssetImageLoaderRequest` reads
  artwork live from the file via AVAsset (`loadLocalFileImage`,
  `imagesDataFromAVMetadataItems:`). Artwork edits in the file WOULD surface;
  title/artist/album edits won't.
- Master's working tree has a proven runtime READ path for a *playing* local
  file: `SPTPlayerTrack.metadata()` / `trackTitle()` / `artistName()` captured
  into `V91TrackMetadataCapture.x.swift`'s in-memory cache — but that's
  display/interception, not persistence.

## Editor pipeline

1. Enumerate Local Files list via `FTPAllSongsDataSource` -> URIs.
2. Resolve `localFileURLForMediaURL:` -> real file path.
3. Parse: MP3 = ID3v2 frames; M4A/AAC = MP4 atoms (`ilst`). Spotify has no
   public writer — need our own pure-Swift parser + writer.
4. Write tags in place, then refresh Spotify's cached view.

## Write-path options (post-research)

- (a) **Display interception (tweak-only, survives core):** hook
  `FTPAllSongsDataSource.trackNameForIndexPath:` /
  `artistNameForIndexPath:` / `albumNameForIndexPath:` plus
  `SPTPlayerTrack.metadata` to overlay edits. No persistence needed.
- (b) **Forced re-scan:** toggle `LocalFilesSettingsModelImpl`
  disable/enable or trigger the media-library change callback, accepting URI
  churn.
- (c) **Core-DB mutation:** blocked — location/schema unknown (C++ opaque).

## Remaining unknowns

- Whether the `spotify:local:artist:album:title:duration` URI must be rewritten
  for playback/display consistency after a tag edit (would break existing
  references and the lyrics synthetic-id mapping).
- Whether a forced re-scan refreshes the core's view or must be mutated.
- Whether runtime probes (Frida / device FS) reveal a core-side store that
  static analysis cannot.

See gradient.md in main's working tree for the full exploration notes.
