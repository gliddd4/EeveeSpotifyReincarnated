import Foundation

public enum MetadataTagKitError: Error, Equatable {
    case unsupportedFormat
    case corruptTag(String)
    case corruptFile(String)
    case audioByteMismatch
}

extension MetadataTagKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "unsupported format"
        case .corruptTag(let message):
            return "corrupt tag: \(message)"
        case .corruptFile(let message):
            return "corrupt file: \(message)"
        case .audioByteMismatch:
            return "audio bytes would be modified; refusing to write"
        }
    }
}
