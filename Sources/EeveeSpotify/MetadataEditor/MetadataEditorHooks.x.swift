import Orion
import UIKit
import Foundation
import ObjectiveC.runtime

// One-time overlay logging per URI: the FTP getters run for every row on every
// layout pass, so a bare writeDebugLog per call would spam the log file.
private let overlayLogQueue = DispatchQueue(label: "com.eeveespotify.metadataeditor.log")
private var _loggedOverlayURIs: Set<String> = []

private func logOverlayOnce(uri: String) {
    overlayLogQueue.sync {
        guard !_loggedOverlayURIs.contains(uri) else { return }
        _loggedOverlayURIs.insert(uri)
        writeDebugLog("[MetadataEditor] overlay active for \(uri)")
    }
}

/// Runtime interface for `_TtC35ListUXPlatform_FreeTierPlaylistImpl21FTPAllSongsDataSource`
/// (Local Files list). Only used to read `trackURIForIndexPath:` on the hook
/// target — the three name getters are hooked through the ClassHook below, and
/// reading the URI this way avoids swizzling a fourth selector.
@objc protocol FTPAllSongsDataSourceInterface {
    func trackURIForIndexPath(_ indexPath: IndexPath) -> NSURL?
    func trackNameForIndexPath(_ indexPath: IndexPath) -> NSString?
    func artistNameForIndexPath(_ indexPath: IndexPath) -> NSString?
    func albumNameForIndexPath(_ indexPath: IndexPath) -> NSString?
}

/// Runtime interface for reading the current track's URI off an SPTPlayerTrack
/// instance. Declared optional so a nil URI can't crash the hook.
@objc protocol SPTPlayerTrackURIInterface {
    func URI() -> NSURL?
}

struct MetadataEditorGroup: HookGroup {}

// Overlays the Local Files list's cached view of the tags. Spotify derives the
// list text from the `spotify:local:` URI (which embeds the import-time tags),
// so edits are applied here instead of to any Spotify-side store.
class FTPAllSongsDataSourceHook: ClassHook<NSObject> {
    typealias Group = MetadataEditorGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl21FTPAllSongsDataSource"

    private func overlayValue(
        for indexPath: IndexPath,
        original: NSString?,
        field: KeyPath<MetadataEdit, String?>
    ) -> NSString? {
        guard let uri = trackURI(for: indexPath),
              uri.hasPrefix("spotify:local:") else {
            return original
        }
        MetadataEditorStore.rememberLocalURI(uri)
        guard let edit = MetadataEditorStore.edits(forURI: uri),
              let edited = edit[keyPath: field], !edited.isEmpty else {
            return original
        }
        logOverlayOnce(uri: uri)
        return NSString(string: edited)
    }

    private func trackURI(for indexPath: IndexPath) -> String? {
        guard let url = Dynamic.convert(target, to: FTPAllSongsDataSourceInterface.self)
            .trackURIForIndexPath(indexPath) else {
            return nil
        }
        return url.absoluteString
    }

    func trackNameForIndexPath(_ indexPath: IndexPath) -> NSString? {
        overlayValue(for: indexPath, original: orig.trackNameForIndexPath(indexPath), field: \.title)
    }

    func artistNameForIndexPath(_ indexPath: IndexPath) -> NSString? {
        overlayValue(for: indexPath, original: orig.artistNameForIndexPath(indexPath), field: \.artist)
    }

    func albumNameForIndexPath(_ indexPath: IndexPath) -> NSString? {
        overlayValue(for: indexPath, original: orig.albumNameForIndexPath(indexPath), field: \.album)
    }
}

// Captures the live OfflineManagerImpl instance whenever Spotify resolves a
// local-file media URL, so MetadataEditorFileService can map `spotify:local:`
// URIs to on-disk file URLs. The 9.1.68 dump confirms no public singleton
// accessor, so this capture is the reliable way to reach the service.
class OfflineManagerImplHook: ClassHook<NSObject> {
    typealias Group = MetadataEditorGroup
    static let targetName = "_TtC17BetamaxOfflineSDK18OfflineManagerImpl"

    func localFileURLForMediaURL(_ mediaURL: NSURL) -> NSURL? {
        MetadataEditorFileService.offlineManagerInstance = target
        return orig.localFileURLForMediaURL(mediaURL)
    }
}

// Overlays the Now Playing metadata getters for local files. Named differently
// from the lyrics' SPTPlayerTrackHook to avoid a same-module redeclaration; the
// two hooks swizzle disjoint selectors (trackTitle/artistName here, metadata/
// URI there).
class MetadataEditorPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = MetadataEditorGroup
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    private func currentLocalURI() -> String? {
        guard let uri = Dynamic.convert(target, to: SPTPlayerTrackURIInterface.self)
            .URI()?.absoluteString,
            uri.hasPrefix("spotify:local:") else {
            return nil
        }
        return uri
    }

    private func overlay(_ original: NSString?, for uri: String?, field: KeyPath<MetadataEdit, String?>) -> NSString? {
        guard let uri = uri,
              let edit = MetadataEditorStore.edits(forURI: uri),
              let edited = edit[keyPath: field], !edited.isEmpty else {
            return original
        }
        logOverlayOnce(uri: uri)
        return NSString(string: edited)
    }

    func trackTitle() -> NSString? {
        let uri = currentLocalURI()
        return overlay(orig.trackTitle(), for: uri, field: \.title)
    }

    func artistName() -> NSString? {
        let uri = currentLocalURI()
        return overlay(orig.artistName(), for: uri, field: \.artist)
    }
}

// Pre-flights every hook target (class + selector) before activating the group;
// Orion fatalErrors at activation on a missing class or mismatched method, so a
// build that lacks any piece skips the whole editor rather than crash.
func activateMetadataEditor() {
    let ftpClass = NSClassFromString("_TtC35ListUXPlatform_FreeTierPlaylistImpl21FTPAllSongsDataSource")
    let offlineClass = NSClassFromString("_TtC17BetamaxOfflineSDK18OfflineManagerImpl")
    let playerName = EeveeSpotify.hookTarget == .latest ? "SPTPlayerTrackImplementation" : "SPTPlayerTrack"
    let playerClass = NSClassFromString(playerName)

    let ftpOK = ftpClass?.instancesRespond(to: Selector(("trackNameForIndexPath:"))) == true
        && ftpClass?.instancesRespond(to: Selector(("artistNameForIndexPath:"))) == true
        && ftpClass?.instancesRespond(to: Selector(("albumNameForIndexPath:"))) == true
        && ftpClass?.instancesRespond(to: Selector(("trackURIForIndexPath:"))) == true
    let offlineOK = offlineClass?.instancesRespond(to: Selector(("localFileURLForMediaURL:"))) == true
    let playerOK = playerClass?.instancesRespond(to: Selector(("trackTitle"))) == true
        && playerClass?.instancesRespond(to: Selector(("artistName"))) == true
        && playerClass?.instancesRespond(to: Selector(("URI"))) == true

    guard ftpOK, offlineOK, playerOK else {
        writeDebugLog("[MetadataEditor] skipped: ftp=\(ftpOK) offline=\(offlineOK) player=\(playerOK)")
        return
    }

    MetadataEditorGroup().activate()
    writeDebugLog("[MetadataEditor] activated")
}
