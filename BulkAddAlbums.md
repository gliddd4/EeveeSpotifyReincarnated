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

## Plan outline

1. Enumerate local files grouped by album (reuse the
   `FTPAllSongsDataSource` seams recorded in gradient.md).
2. Present album selection UI.
3. Resolve each chosen track's `spotify:local:` URI and add to the target
   playlist via the existing add-tracks endpoint.
