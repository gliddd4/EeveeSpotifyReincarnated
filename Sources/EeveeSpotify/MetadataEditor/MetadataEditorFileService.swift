import Foundation
import Orion
import ObjectiveC.runtime

/// Runtime interface for `BetamaxOfflineSDK.OfflineManagerImpl`'s
/// `-localFileURLForMediaURL:` bridge (media URL -> on-disk file URL).
@objc protocol OfflineManagerFileURLInterface {
    func localFileURLForMediaURL(_ mediaURL: NSURL) -> NSURL?
}

/// Runtime interface for probing a class-level singleton accessor on
/// `OfflineManagerImpl`. The 9.1.68 dump does not confirm any of these
/// accessors, so this is a guarded best-effort only — the reliable path is the
/// instance captured by `OfflineManagerImplHook`.
@objc protocol OfflineManagerClassAccessorInterface {
    func shared() -> AnyObject?
    func defaultInstance() -> AnyObject?
    func sharedInstance() -> AnyObject?
    func defaultManager() -> AnyObject?
}

/// Resolves `spotify:local:` URIs to on-disk file URLs (via OfflineManagerImpl)
/// and reads/writes MP3/M4A tags through MetadataTagKit. All file I/O runs on a
/// private serial queue; failures are logged and reported, never thrown to the
/// caller.
enum MetadataEditorFileService {
    private static let queue = DispatchQueue(label: "com.eeveespotify.metadatameditor.file")
    private static let instanceLock = NSLock()
    private static var _offlineManagerInstance: AnyObject?

    /// The live OfflineManagerImpl instance. Set by `OfflineManagerImplHook`
    /// when Spotify resolves a local-file URL; falls back to a guarded
    /// class-accessor lookup when no instance has been captured yet.
    static var offlineManagerInstance: AnyObject? {
        get {
            instanceLock.lock()
            let cached = _offlineManagerInstance
            instanceLock.unlock()
            if let cached { return cached }
            return resolveOfflineManagerInstance()
        }
        set {
            instanceLock.lock()
            _offlineManagerInstance = newValue
            instanceLock.unlock()
        }
    }

    /// Reads the on-disk tags for a local-track URI (used to prefill the edit
    /// form). Returns nil when the file can't be resolved or parsed.
    static func readMetadata(forURI uri: String) -> TrackMetadata? {
        queue.sync {
            guard let fileURL = resolveFileURL(forURI: uri) else {
                writeDebugLog("[MetadataEditor] read: cannot resolve file for \(uri)")
                return nil
            }
            do {
                return try TagEditor.read(from: fileURL)
            } catch {
                writeDebugLog("[MetadataEditor] read failed for \(uri): \(error)")
                return nil
            }
        }
    }

    /// Writes an edit to the on-disk file for a local-track URI. Serialized on a
    /// background queue; returns whether the write succeeded. A nil field in the
    /// edit leaves that tag untouched.
    static func apply(_ edit: MetadataEdit, forURI uri: String) -> Bool {
        queue.sync {
            guard let fileURL = resolveFileURL(forURI: uri) else {
                writeDebugLog("[MetadataEditor] apply: cannot resolve file for \(uri)")
                return false
            }
            do {
                let metadata = TrackMetadata(title: edit.title, artist: edit.artist, album: edit.album)
                try TagEditor.write(metadata, to: fileURL)
                writeDebugLog("[MetadataEditor] applied edits to \(fileURL.lastPathComponent) for \(uri)")
                return true
            } catch {
                writeDebugLog("[MetadataEditor] write failed for \(uri): \(error)")
                return false
            }
        }
    }

    /// Maps a `spotify:local:` URI to the on-disk file URL, or nil.
    private static func resolveFileURL(forURI uri: String) -> URL? {
        guard uri.hasPrefix("spotify:local:") else { return nil }
        guard let instance = offlineManagerInstance else {
            writeDebugLog("[MetadataEditor] resolve: OfflineManagerImpl unavailable for \(uri)")
            return nil
        }
        guard let mediaURL = NSURL(string: uri) else {
            writeDebugLog("[MetadataEditor] resolve: invalid media URL \(uri)")
            return nil
        }
        guard let fileURL = Dynamic.convert(instance, to: OfflineManagerFileURLInterface.self)
            .localFileURLForMediaURL(mediaURL) else {
            writeDebugLog("[MetadataEditor] resolve: localFileURLForMediaURL returned nil for \(uri)")
            return nil
        }
        return fileURL as URL
    }

    /// Best-effort singleton lookup through class-level accessors. Each accessor
    /// is guarded with class_getClassMethod so a missing selector never reaches
    /// the runtime. The 9.1.68 dump confirms no accessor, so this usually
    /// resolves nothing and the hook-captured instance is what the service uses.
    private static func resolveOfflineManagerInstance() -> AnyObject? {
        guard let cls = NSClassFromString("_TtC17BetamaxOfflineSDK18OfflineManagerImpl") else {
            return nil
        }

        let dynamic = Dynamic(cls).as(
            interface: OfflineManagerClassAccessorInterface.self,
            protocol: OfflineManagerClassAccessorInterface.self
        )

        if class_getClassMethod(cls, Selector(("shared"))) != nil,
           let instance = dynamic.shared() {
            return instance
        }
        if class_getClassMethod(cls, Selector(("defaultInstance"))) != nil,
           let instance = dynamic.defaultInstance() {
            return instance
        }
        if class_getClassMethod(cls, Selector(("sharedInstance"))) != nil,
           let instance = dynamic.sharedInstance() {
            return instance
        }
        if class_getClassMethod(cls, Selector(("defaultManager"))) != nil,
           let instance = dynamic.defaultManager() {
            return instance
        }
        return nil
    }
}
