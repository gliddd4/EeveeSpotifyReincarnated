import Foundation

/// A single track's tag edits, keyed by its `spotify:local:artist:album:title:duration`
/// URI. Title/artist/album are the display-interception overlay values AND the
/// seed for the on-disk write.
struct MetadataEdit: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
}

/// Per-URI metadata edit store, persisted in UserDefaults as JSON Data.
/// Mirrors SponsorBlockMySubmissionsStore's NSLock + Data encode/decode idiom;
/// Spotify has no persistent local-file metadata store, so this overlay IS the
/// cached view the UI getters read from.
enum MetadataEditorStore {
    private static let key = "MetadataEditor.Edits"
    private static let lock = NSLock()
    private static let knownURIsLock = NSLock()
    private static var _knownURIs: Set<String> = []
    static let changedNotification = Notification.Name("EeveeMetadataEditorChanged")

    /// Remembers a `spotify:local:` URI as it appears in the Local Files list
    /// (captured by FTPAllSongsDataSourceHook while the list renders). This
    /// seeds the settings list so rows exist to edit even before any edit is
    /// stored — the store alone can't be the UI source, or the editor would be
    /// unreachable (empty store -> no row -> no edit).
    static func rememberLocalURI(_ uri: String) {
        guard uri.hasPrefix("spotify:local:") else { return }
        knownURIsLock.lock()
        let isNew = _knownURIs.insert(uri).inserted
        knownURIsLock.unlock()
        if isNew {
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    /// Every `spotify:local:` URI seen this session, sorted for display.
    static var knownURIs: [String] {
        knownURIsLock.lock()
        defer { knownURIsLock.unlock() }
        return Array(_knownURIs).sorted()
    }

    /// The edit for a URI, or nil when the track is untouched.
    static func edits(forURI uri: String) -> MetadataEdit? {
        all()[uri]
    }

    /// Persists an edit for a URI, replacing any previous one.
    static func set(_ edit: MetadataEdit, forURI uri: String) {
        var dict = all()
        dict[uri] = edit
        save(dict)
    }

    /// Drops the overlay for a URI (the on-disk tags are left as written).
    static func remove(forURI uri: String) {
        var dict = all()
        dict.removeValue(forKey: uri)
        save(dict)
    }

    /// Removes every edit overlay.
    static func clear() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key)
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Every URI that currently has an edit.
    static var allURIs: [String] {
        Array(all().keys)
    }

    /// The full edit map, for iteration/enumeration.
    static func all() -> [String: MetadataEdit] {
        lock.lock(); defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: MetadataEdit].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ dict: [String: MetadataEdit]) {
        lock.lock()
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
