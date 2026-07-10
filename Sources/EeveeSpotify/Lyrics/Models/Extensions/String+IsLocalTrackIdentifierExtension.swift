import Foundation

extension String {
    var isLocalTrackIdentifier: Bool {
        self.hasPrefix("spotify:local:")
    }

    /// True for a normal Spotify track id/URI. Spotify track ids are 22 chars of
    /// [A-Za-z0-9]; local files instead surface a short numeric/internal id
    /// (e.g. the lyrics request for a local file is /color-lyrics/v2/track/173).
    /// Anything that isn't a real Spotify id is treated as a local track so we
    /// fall back to a title+artist lyrics source (Genius) instead of one that
    /// requires a real Spotify track id (SpicyLyrics).
    var isLikelySpotifyTrackId: Bool {
        if self.hasPrefix("spotify:track:") { return true }
        // Spotify ids are 22 chars of ASCII [A-Za-z0-9]; use ASCII-only check so
        // non-ASCII letters/digits can't be misclassified as a real Spotify id.
        return self.count >= 20
            && self.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Local for our purposes: an explicit spotify:local: URI OR any id that
    /// isn't a real Spotify track id (covers the local-file numeric id).
    var isLocalOrNonSpotifyTrackId: Bool {
        self.isLocalTrackIdentifier || !self.isLikelySpotifyTrackId
    }
}
