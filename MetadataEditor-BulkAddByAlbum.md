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

## The open problem

Spotify caches title/artist/album from import time; editing the file alone
won't update the UI until the cache refreshes. Unknowns:

- Where the `spotify:local:` metadata cache lives and its schema.
- Whether a forced re-scan / re-import refreshes it, or it must be mutated.
- Whether the `spotify:local:artist:album:title:duration` URI must be rewritten
  for playback/display consistency after a tag edit.

See gradient.md in main's working tree for the full exploration notes.
