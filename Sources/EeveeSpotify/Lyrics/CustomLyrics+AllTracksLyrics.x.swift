import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

// SPTPlayerTrack metadata hooks not compatible with 9.1.x
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        // On 9.1.x the metadata injection is owned exclusively by
        // SPTPlayerTrackMetadataV91Hook (activated in its own group) to avoid
        // two hooks swizzling the same selector. Here we just pass through.
        guard EeveeSpotify.hookTarget != .v91 else {
            return orig.metadata()
        }
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> SPTURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              uri?.spt_trackIdentifier().isLocalTrackIdentifier == true else {

            if let trackId = uri?.spt_trackIdentifier(),
               trackId.hasPrefix("spotify:track:") {
                let id = String(trackId.dropFirst("spotify:track:".count))
                if !id.isEmpty {
                    prefetchLyricsIfNeeded(trackId: id)
                }
            }

            return uri
        }

        return Dynamic.convert(NSURL(string: "spotify:track:")!, to: SPTURL.self)
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // LyricsScrollProvider class may not exist on 9.1.x
        : "Lyrics_CoreImpl.LyricsScrollProvider"
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x  
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// V91-compatible URI hook — converts local URIs to fake track URIs so Spotify
// fires /color-lyrics/v2 which our network hooks can intercept.
// Only hooks URI() (not metadata()) because metadata() is incompatible with 9.1.x.
// Return type MUST match SPTPlayerTrack.URI() exactly: optional NSURL (see the
// baseline SPTPlayerTrackHook). A non-optional or wrong-class return type is a
// method-signature mismatch that makes Orion fatalError() at dyld init.
class SPTPlayerTrackURIV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static let targetName = "SPTPlayerTrack"

    func URI() -> NSURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {

            if let uriString = uri?.absoluteString,
               uriString.hasPrefix("spotify:track:") {
                let trackId = uriString.replacingOccurrences(of: "spotify:track:", with: "")
                if !trackId.isEmpty {
                    prefetchLyricsIfNeeded(trackId: trackId)
                }
            }

            return uri
        }

        writeDebugLog("[LyricsV91] URI override: local -> fake track URI")
        return NSURL(string: "spotify:track:")!
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        // Capture local metadata from the REAL track URI. The override must not
        // be enabled yet: once shouldOverrideLocalTrackURI is true,
        // SPTPlayerTrackURIV91Hook rewrites the URI to an empty `spotify:track:`,
        // so spt_trackIdentifier() returns "" and the local check below fails
        // (capture would never run and Genius would get empty title/artist).
        if let track = nowPlayingScrollViewController?.loadedTrack {
            let trackId = track.URI().spt_trackIdentifier()
            let title = track.trackTitle()
            let artist = track.artistName()
            let isLocal = trackId.isLocalTrackIdentifier
            writeDebugLog("[LyricsV91] NPVScroll viewWillAppear: trackId=\(trackId) local=\(isLocal)")
            if isLocal {
                capturedTrackTitle = title
                capturedArtistName = artist
                capturedTrackId = trackId
                writeDebugLog("[V91] captured local track: title=\(title) artist=\(artist)")
                prefetchLyricsIfNeeded(trackId: trackId)
            }
        } else {
            writeDebugLog("[LyricsV91] NPVScroll viewWillAppear: no track available")
        }

        // Now enable the URI override so Spotify fires /color-lyrics/v2 for the
        // (rewritten) local track. Keeps the capturedTrackId fallback intact.
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// V91-compatible hook — forces LyricsScrollProvider to report lyrics as enabled
// for ALL tracks, including local files. Without this, Spotify's internal
// lyrics availability check rejects local files based on their URI.
// NOTE: On 9.1.x the Lyrics_CoreImpl module no longer exists (lyrics was
// rewritten to Lyrics_TextComponentImpl), so this target resolves to a dummy
// UIView to avoid a dyld crash. The real lyrics-enabling point on 9.1.x must
// be found in the new Lyrics_TextComponentImpl architecture.
// Separate group so this hook only registers when the real
// Lyrics_CoreImpl.LyricsScrollProvider class actually exists. On 9.1.x that
// class is gone (lyrics rewritten to Lyrics_TextComponentImpl), so the group
// stays unactivated and the hook is never registered — avoiding the dyld
// fatalError that the old dummy-"UIView" target caused (UIView has no
// isEnabledForTrack: method for Orion to swizzle).
struct V91LyricsScrollProviderGroup: HookGroup {}

// 9.1.x lyrics-availability GATE: inject `has_lyrics: true` into
// SPTPlayerTrack.metadata() so Spotify fires `/color-lyrics/v2` for every
// track (incl. locals). SPTPlayerTrackHook is a no-op pass-through on 9.1.x,
// so this is the sole metadata injector (no double-swizzle). Deliberately has
// NO logging: metadata() is called on a background queue by Spotify and
// writeDebugLog (file I/O) there triggered an Orion fatalError / queue crash
// on normal tracks. Mirrors SPTPlayerTrackHook.metadata() exactly.
struct V91LyricsMetadataGroup: HookGroup {}

class SPTPlayerTrackMetadataV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsMetadataGroup
    static let targetName = "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
}

class LyricsScrollProviderV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsScrollProviderGroup
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"

    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        let isLocal = (track.URI() as? SPTURL)?.spt_trackIdentifier().isLocalTrackIdentifier == true
        writeDebugLog("[LyricsV91] LyricsScrollProvider.isEnabledForTrack called: local=\(isLocal)")
        return true
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Dummy target for 9.1.6
        : "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
