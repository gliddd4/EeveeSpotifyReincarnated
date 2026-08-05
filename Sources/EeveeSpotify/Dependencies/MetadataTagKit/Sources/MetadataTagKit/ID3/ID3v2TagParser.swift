import Foundation

public enum ID3v2TagParser {

    struct ID3Tag {
        let versionMajor: UInt8
        let revision: UInt8
        let totalLength: Int
        let frames: [ID3Frame]
    }

    struct ID3Frame {
        let id: String
        let statusFlags: UInt8
        let formatFlags: UInt8
        let data: Data
    }

    public static func readMetadata(from data: Data) throws -> TrackMetadata {
        guard let tag = try readTag(from: data) else { return TrackMetadata() }
        var title: String?
        var artist: String?
        var album: String?
        var apics: [(type: UInt8, image: Data)] = []
        for frame in tag.frames {
            switch frame.id {
            case "TIT2":
                if title == nil {
                    let value = parseTextFrame(frame.data)
                    title = value.isEmpty ? nil : value
                }
            case "TPE1":
                if artist == nil {
                    let value = parseTextFrame(frame.data)
                    artist = value.isEmpty ? nil : value
                }
            case "TALB":
                if album == nil {
                    let value = parseTextFrame(frame.data)
                    album = value.isEmpty ? nil : value
                }
            case "APIC":
                if let picture = parseAPIC(frame.data) { apics.append(picture) }
            default:
                break
            }
        }
        let artwork = apics.first(where: { $0.type == 3 })?.image ?? apics.first?.image
        return TrackMetadata(title: title, artist: artist, album: album, artwork: artwork)
    }

    static func readTag(from data: Data) throws -> ID3Tag? {
        guard data.count >= 10,
              data[data.startIndex] == 0x49,
              data[data.startIndex + 1] == 0x44,
              data[data.startIndex + 2] == 0x33 else { return nil }
        let versionMajor = data[data.startIndex + 3]
        guard versionMajor == 3 || versionMajor == 4 else { return nil }
        let revision = data[data.startIndex + 4]
        let flags = data[data.startIndex + 5]
        // The header size field is synchsafe in both v2.3 and v2.4 and covers frames + padding.
        let tagSize = syncsafeInt(Array(data[(data.startIndex + 6)...(data.startIndex + 9)]))
        // The v2.4 tag-size excludes header and footer; the tag's total byte span is
        // header + tagSize + optional footer. Audio starts after the whole span.
        let hasFooter = versionMajor == 4 && flags & 0x10 != 0
        let totalLength = 10 + tagSize + (hasFooter ? 10 : 0)
        guard totalLength <= data.count else {
            throw MetadataTagKitError.corruptTag("ID3 tag size \(tagSize) exceeds available data")
        }
        let tagEnd = data.startIndex + 10 + tagSize
        var offset = data.startIndex + 10
        if flags & 0x40 != 0 {
            // Extended header: v2.3 stores its size excluding the 4 size bytes, v2.4 including them (synchsafe).
            guard offset + 4 <= tagEnd else {
                throw MetadataTagKitError.corruptTag("extended header exceeds tag bounds")
            }
            let sizeField = Array(data[offset..<(offset + 4)])
            let extLength = versionMajor == 4 ? syncsafeInt(sizeField) : int32BE(sizeField) + 4
            guard extLength >= 4, offset + extLength <= tagEnd else {
                throw MetadataTagKitError.corruptTag("extended header size \(extLength) exceeds tag bounds")
            }
            offset += extLength
        }
        let tagUnsync = flags & 0x80 != 0
        var frames: [ID3Frame] = []
        while offset + 10 <= tagEnd {
            let idBytes = Array(data[offset..<(offset + 4)])
            // Frame IDs are [A-Z0-9]; anything else (e.g. zero padding) ends the frame list.
            let isPlausibleID = idBytes.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
            }
            guard isPlausibleID else { break }
            let sizeField = Array(data[(offset + 4)..<(offset + 8)])
            // v2.3 uses plain big-endian frame sizes, v2.4 synchsafe.
            let frameSize = versionMajor == 4 ? syncsafeInt(sizeField) : int32BE(sizeField)
            guard frameSize >= 0, offset + 10 + frameSize <= tagEnd else {
                throw MetadataTagKitError.corruptTag("frame \(String(decoding: idBytes, as: UTF8.self)) size \(frameSize) exceeds remaining tag data")
            }
            let statusFlags = data[offset + 8]
            var formatFlags = data[offset + 9]
            var frameData = Data(data[(offset + 10)..<(offset + 10 + frameSize)])
            // Unsynchronisation stores every 0xFF as 0xFF 0x00; undo that in the frame payload.
            // v2.4 per-frame unsync is format-flags bit 1 (0x02); bit 0 (0x01) is the
            // data-length-indicator, which must NOT be de-unsynchronised.
            if tagUnsync || (versionMajor == 4 && (formatFlags & 0x02) != 0) {
                frameData = deunsynchronise(frameData)
                formatFlags = formatFlags & ~0x02
            }
            frames.append(ID3Frame(
                id: String(decoding: idBytes, as: UTF8.self),
                statusFlags: statusFlags,
                formatFlags: formatFlags,
                data: frameData
            ))
            offset += 10 + frameSize
        }
        return ID3Tag(versionMajor: versionMajor, revision: revision, totalLength: totalLength, frames: frames)
    }

    static func syncsafeInt(_ bytes: [UInt8]) -> Int {
        var b = bytes
        while b.count < 4 { b.insert(0, at: 0) }
        return (Int(b[0] & 0x7F) << 21) | (Int(b[1] & 0x7F) << 14) | (Int(b[2] & 0x7F) << 7) | Int(b[3] & 0x7F)
    }

    static func intToSyncsafe(_ value: Int) -> [UInt8] {
        let v = max(0, min(value, 0x0FFFFFFF))
        return [
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F),
        ]
    }

    static func int32BE(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 4 else { return 0 }
        return (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
    }

    static func deunsynchronise(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            out.append(data[i])
            if data[i] == 0xFF, i + 1 < data.endIndex, data[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    static func parseTextFrame(_ data: Data) -> String {
        guard let first = data.first else { return "" }
        let encoding = first
        let firstValue = firstValuePrefix(data.dropFirst(), encoding: encoding)
        let payload = stripStringTerminator(firstValue, encoding: encoding)
        return ID3v2TextEncoding.decode(payload, encoding: encoding)
    }

    // v2.4 text frames can carry multiple values separated by the encoding's terminator;
    // Spotify shows only the first, so cut the payload at the first terminator.
    static func firstValuePrefix(_ data: Data, encoding: UInt8) -> Data {
        if encoding == 1 || encoding == 2 {
            var idx = data.startIndex
            while idx + 1 < data.endIndex {
                if data[idx] == 0 && data[idx + 1] == 0 {
                    return data.prefix(upTo: idx)
                }
                idx += 1
            }
            return data
        }
        if let terminator = data.firstIndex(of: 0) {
            return data.prefix(upTo: terminator)
        }
        return data
    }

    static func stripStringTerminator(_ data: Data, encoding: UInt8) -> Data {
        guard !data.isEmpty else { return data }
        if encoding == 1 || encoding == 2 {
            if data.count >= 2, data[data.endIndex - 2] == 0, data[data.endIndex - 1] == 0 {
                return data.dropLast(2)
            }
            return data
        }
        if data[data.endIndex - 1] == 0 {
            return data.dropLast()
        }
        return data
    }

    static func parseAPIC(_ data: Data) -> (type: UInt8, image: Data)? {
        guard data.count >= 1 else { return nil }
        let encoding = data[data.startIndex]
        var idx = data.startIndex + 1
        while idx < data.endIndex && data[idx] != 0 { idx += 1 }
        guard idx < data.endIndex else { return nil }
        idx += 1
        guard idx < data.endIndex else { return nil }
        let pictureType = data[idx]
        idx += 1
        let multiByteTerminator = encoding == 1 || encoding == 2
        while idx < data.endIndex {
            if data[idx] == 0 {
                if multiByteTerminator {
                    if idx + 1 < data.endIndex && data[idx + 1] == 0 {
                        idx += 2
                        break
                    }
                    if idx + 1 >= data.endIndex {
                        idx += 1
                        break
                    }
                    idx += 1
                } else {
                    idx += 1
                    break
                }
            } else {
                idx += 1
            }
        }
        guard idx <= data.endIndex else { return nil }
        guard idx < data.endIndex else { return nil }
        let image = Data(data[idx...])
        guard !image.isEmpty else { return nil }
        return (pictureType, image)
    }
}
