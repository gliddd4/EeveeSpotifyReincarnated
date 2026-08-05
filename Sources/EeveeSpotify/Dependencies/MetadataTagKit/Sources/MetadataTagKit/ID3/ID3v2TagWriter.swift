import Foundation

public enum ID3v2TagWriter {

    public static func rewrite(data: Data, edits: TrackMetadata) throws -> Data {
        if edits.title == nil, edits.artist == nil, edits.album == nil, edits.artwork == nil {
            return data
        }
        guard let existing = try ID3v2TagParser.readTag(from: data) else {
            if data.count >= 3, data.starts(with: Data("ID3".utf8)) {
                throw MetadataTagKitError.corruptTag("unsupported ID3 version")
            }
            var frames: [ID3v2TagParser.ID3Frame] = []
            return try buildTag(data: data, version: 3, revision: 0, existingLength: 0, frames: applyEdits(edits, to: frames))
        }
        var frames = applyEdits(edits, to: existing.frames)
        return try buildTag(data: data, version: existing.versionMajor, revision: existing.revision, existingLength: existing.totalLength, frames: frames)
    }

    private static func applyEdits(_ edits: TrackMetadata, to frames: [ID3v2TagParser.ID3Frame]) -> [ID3v2TagParser.ID3Frame] {
        var result = frames
        if let title = edits.title {
            result = replacingFrame(id: "TIT2", in: result, with: textFrame(id: "TIT2", text: title))
        }
        if let artist = edits.artist {
            result = replacingFrame(id: "TPE1", in: result, with: textFrame(id: "TPE1", text: artist))
        }
        if let album = edits.album {
            result = replacingFrame(id: "TALB", in: result, with: textFrame(id: "TALB", text: album))
        }
        if let artwork = edits.artwork {
            result = replacingFrame(id: "APIC", in: result, with: artworkFrame(image: artwork))
        }
        return result
    }

    private static func buildTag(data: Data, version: UInt8, revision: UInt8, existingLength: Int, frames: [ID3v2TagParser.ID3Frame]) throws -> Data {
        var framesData = Data()
        for frame in frames {
            framesData.append(encodedFrame(frame, version: version))
        }
        // Keep total tag length (and file size) stable where possible: reuse the old
        // tag's padding so CBR durations derived from file size don't drift. Only grow
        // when the new frames outgrow the old tag, and then keep >= 1KB of padding.
        let minimalTotal = 10 + framesData.count + 1024
        let targetTotal = max(existingLength, minimalTotal)
        let padding = Data(count: targetTotal - 10 - framesData.count)
        let tagSize = targetTotal - 10

        var header = Data([0x49, 0x44, 0x33])
        header.append(version)
        header.append(revision)
        header.append(0)
        header.append(contentsOf: ID3v2TagParser.intToSyncsafe(tagSize))

        let audio = data.dropFirst(existingLength)
        return header + framesData + padding + audio
    }

    static func textFrame(id: String, text: String) -> ID3v2TagParser.ID3Frame {
        var payload = Data([0x03])
        payload.append(contentsOf: ID3v2TextEncoding.encode(text, encoding: 3))
        return ID3v2TagParser.ID3Frame(id: id, statusFlags: 0, formatFlags: 0, data: payload)
    }

    static func artworkFrame(image: Data) -> ID3v2TagParser.ID3Frame {
        var payload = Data([0x00])
        let mime: String
        if image.starts(with: [0xFF, 0xD8]) {
            mime = "image/jpeg"
        } else if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else {
            mime = "image/jpeg"
        }
        payload.append(contentsOf: mime.utf8)
        payload.append(0x00)
        payload.append(0x03)
        payload.append(0x00)
        payload.append(image)
        return ID3v2TagParser.ID3Frame(id: "APIC", statusFlags: 0, formatFlags: 0, data: payload)
    }

    static func encodedFrame(_ frame: ID3v2TagParser.ID3Frame, version: UInt8) -> Data {
        var out = Data()
        out.append(contentsOf: frame.id.utf8)
        let size = frame.data.count
        if version == 4 {
            out.append(contentsOf: ID3v2TagParser.intToSyncsafe(size))
        } else {
            out.append(contentsOf: [
                UInt8((size >> 24) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8(size & 0xFF),
            ])
        }
        out.append(frame.statusFlags)
        out.append(frame.formatFlags)
        out.append(frame.data)
        return out
    }

    static func replacingFrame(id: String, in frames: [ID3v2TagParser.ID3Frame], with replacement: ID3v2TagParser.ID3Frame) -> [ID3v2TagParser.ID3Frame] {
        var result: [ID3v2TagParser.ID3Frame] = []
        var inserted = false
        for frame in frames {
            if frame.id == id {
                if !inserted {
                    result.append(replacement)
                    inserted = true
                }
            } else {
                result.append(frame)
            }
        }
        if !inserted {
            result.append(replacement)
        }
        return result
    }
}
