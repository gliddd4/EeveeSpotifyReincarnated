# BulkAddAlbums

Bulk add local files to a playlist, grouped by album.

## Goal

Select an album (or the whole Local Files library) and add every track that
belongs to it into a chosen playlist in one operation, instead of per-track
context-menu actions.

## Current state

Research only — no code on this branch yet. This branch diverges from the
latest changes in main and carries only this overview (matching the branch
name). No compatibility concerns: nothing here depends on main's lyrics
internals yet.

## Dependencies

Requires the metadata editor backend from `MetadataEditor/BulkAddByAlbum`
(album identity for local files is unreliable until tags are editable), and a
playlist-add API path. See that branch's overview for the disk/tag work.

## Verified seams (static dump of 9.1.68, spotify_classes.txt)

- `FTPAllSongsDataSource` — real class
  `_TtC35ListUXPlatform_FreeTierPlaylistImpl21FTPAllSongsDataSource`
  (spotify_classes.txt:339623 `trackURIForIndexPath:`, :339624
  `albumNameForIndexPath:`). Conforms to `SPTFreeTierAllSongsDataSource`;
  ivars `playlistUrl`, `playlistPlatformModel` (`<SPTPlaylistModel>`),
  `collectionPlatform`, `tracks: [ListItem]`. Exposes
  `numberOfSectionsForAllSongs`, `numberOfRowsInSection:`,
  `trackRowIDForIndexPath:`. Gate on `allSongsDataSourceLoads` /
  `hasDataSourceLoadedForAllSongs`.
- `OfflineManagerImpl` —
  `_TtC17BetamaxOfflineSDK18OfflineManagerImpl`, line 202160
  `localFileURLForMediaURL:` (+ `localFileSizeForMediaURL:`).
- `SPTPlaylistModel` — `@protocol` at line 37869;
  `addTrackURLs:toPlaylistURL:bySource:fromContext:completion:` at 37875
  (4-arg saveSource variant at 37876). Implemented by
  `_TtC29Playlist_PlaylistPlatformImpl35PlaylistPlatformModelImplementation`
  (line 299879; construction needs internal operation objects — prefer reusing
  the ready-made `<SPTPlaylistModel>` ivar on `FTPAllSongsDataSource`).
- No `PlaylistPicker`/`SPTPlaylistPickerView` in the dump. The modern add sheet
  is `PlaylistCuration_AddToPlaylistImpl` (ATP): `AddToPlaylistService`
  (Mobius SPTService, line 333615), `ATPAddToPlaylistAction` (SPAction, line
  333681), `ATPViewController` (line 333507), `ATPMultiSelectSession`.
  Driving Spotify's own sheet means touching internal Swift (Mobius) — fragile.

## Recommended approach

1. Hook the existing `FTPAllSongsDataSource` instance (Orion hookClass on the
   Swift name) — don't construct your own.
2. Build album → [URI] from `numberOfSectionsForAllSongs` /
   `numberOfRowsInSection:` + `trackURIForIndexPath:` +
   `albumNameForIndexPath:`. Album→URI resolution is free —
   `trackURIForIndexPath:` already yields `spotify:local:` URIs.
3. Add via the data source's existing `playlistPlatformModel` ivar calling
   `addTrackURLs:...completion:` directly.
4. Present a custom tweak-owned album-list sheet (repo already ships UI);
   present via `SPTUIPresentationService`. Avoid the ATP/Mobius path.

## Open risks

- Whether the backend accepts `spotify:local:` URIs in `addTrackURLs:`, or
  whether the target should be the on-device local playlist (`playlistUrl`
  ivar) rather than a cloud playlist. Needs a runtime probe first.
- The doc's original MetadataEditor dependency only matters for editable tag
  fixes, not for the add itself.
