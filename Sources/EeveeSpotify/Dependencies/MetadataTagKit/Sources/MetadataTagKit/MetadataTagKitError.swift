import Foundation

public enum MetadataTagKitError: Error, Equatable {
    case unsupportedFormat
    case corruptTag(String)
    case corruptFile(String)
    case audioByteMismatch
}
