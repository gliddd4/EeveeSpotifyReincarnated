import Foundation

public enum AudioFormat: Equatable {
    case mp3
    case m4a
    case unsupported
}

public enum FormatDetector {
    public static func detect(_ data: Data) -> AudioFormat {
        if data.count >= 10, data.starts(with: Data("ID3".utf8)) {
            // An "ID3" header classifies as mp3 even with an unsupported version byte;
            // the tag parser throws corruptTag instead of this detector masking it.
            let versionMajor = data[data.startIndex + 3]
            if versionMajor == 3 || versionMajor == 4 {
                return .mp3
            }
            return .mp3
        }
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let size = (Int(data[data.startIndex]) << 24)
                | (Int(data[data.startIndex + 1]) << 16)
                | (Int(data[data.startIndex + 2]) << 8)
                | Int(data[data.startIndex + 3])
            if size >= 8, size <= data.count {
                return .m4a
            }
        }
        if data.count >= 8, data.starts(with: Data("moov".utf8)) {
            return .m4a
        }
        return .unsupported
    }
}
