import Foundation

public enum TagEditor {
    public static func read(from url: URL) throws -> TrackMetadata {
        let data = try Data(contentsOf: url)
        switch FormatDetector.detect(data) {
        case .mp3:
            return try ID3v2TagParser.readMetadata(from: data)
        case .m4a:
            return try M4AIlstEditor.readMetadata(from: data)
        case .unsupported:
            throw MetadataTagKitError.unsupportedFormat
        }
    }

    public static func write(_ edits: TrackMetadata, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let output: Data
        switch FormatDetector.detect(data) {
        case .mp3:
            output = try ID3v2TagWriter.rewrite(data: data, edits: edits)
        case .m4a:
            output = try M4AIlstEditor.write(edits, to: data)
        case .unsupported:
            throw MetadataTagKitError.unsupportedFormat
        }
        try output.write(to: url, options: .atomic)
    }
}
