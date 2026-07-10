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
// Return type MUST match SPTPlayerTrack.URI() exactly: it returns an OPTIONAL
// NSURL (see baseline SPTPlayerTrackHook). A non-optional or wrong-class return
// type is a method-signature mismatch that makes Orion fatalError() at dyld init.
class SPTPlayerTrackURIV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static let targetName = "SPTPlayerTrack"

    func URI() -> NSURL? {
        let rawUri = orig.URI() as? SPTURL

        guard shouldOverrideLocalTrackURI,
              rawUri?.spt_trackIdentifier()?.isLocalTrackIdentifier == true else {
            let trackId = rawUri?.spt_trackIdentifier()
            if let trackId = trackId, trackId.hasPrefix("spotify:track:") {
                let id = String(trackId.dropFirst("spotify:track:".count))
                if !id.isEmpty {
                    prefetchLyricsIfNeeded(trackId: id)
                }
            }
            return orig.URI()
        }

        writeDebugLog("[LyricsV91] URI override: local -> fake track URI")
        return Dynamic.convert(NSURL(string: "spotify:track:")!, to: SPTURL.self)
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        // Trigger prefetch for local tracks — statefulPlayer is nil on 9.1.x,
        // so we use nowPlayingScrollViewController?.loadedTrack as fallback.
        if let track = nowPlayingScrollViewController?.loadedTrack {
            let trackId = track.URI().spt_trackIdentifier()
            let isLocal = trackId.isLocalTrackIdentifier
            writeDebugLog("[LyricsV91] NPVScroll viewWillAppear: trackId=\(trackId) local=\(isLocal)")
            if isLocal {
                capturedTrackTitle = track.trackTitle()
                capturedArtistName = track.artistName()
                capturedTrackId = trackId
                writeDebugLog("[LyricsV91] Local track detected — title=\(capturedTrackTitle ?? "?") artist=\(capturedArtistName ?? "?")")
                prefetchLyricsIfNeeded(trackId: trackId)
            }
        } else {
            writeDebugLog("[LyricsV91] NPVScroll viewWillAppear: no track available")
        }
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
class LyricsScrollProviderV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Lyrics_CoreImpl.LyricsScrollProvider doesn't exist on 9.1.x
        : "Lyrics_CoreImpl.LyricsScrollProvider"

    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        let isLocal = track.URI().spt_trackIdentifier().isLocalTrackIdentifier
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
