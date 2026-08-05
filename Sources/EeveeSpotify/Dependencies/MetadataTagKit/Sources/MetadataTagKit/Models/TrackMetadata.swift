import Foundation

public struct TrackMetadata: Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: Data?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artwork: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }
}
