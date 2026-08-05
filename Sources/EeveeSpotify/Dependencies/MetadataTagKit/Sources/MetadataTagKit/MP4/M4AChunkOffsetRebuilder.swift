import Foundation

internal enum M4AChunkOffsetRebuilder {
    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "udta", "meta", "ilst",
    ]

    static func rebuild(_ data: Data, moov: MP4BoxReader.Box, originalMoovEnd: Int, delta: Int64) throws -> Data {
        var result = data
        guard moov.start + 8 <= result.count else {
            throw MetadataTagKitError.corruptFile("moov header out of bounds")
        }
        // Re-read the moov header inside the passed data: the rebuilt moov may have a different size than the box described by `moov`.
        let size32 = MP4BoxReader.readUInt32BE(result, at: moov.start)
        let moovEnd: Int
        if size32 == 1 {
            guard moov.start + 16 <= result.count else {
                throw MetadataTagKitError.corruptFile("truncated moov header")
            }
            let largeSize = MP4BoxReader.readUInt64BE(result, at: moov.start + 8)
            guard largeSize >= 16, largeSize <= UInt64(Int.max) else {
                throw MetadataTagKitError.corruptFile("invalid moov size")
            }
            moovEnd = moov.start + Int(largeSize)
        } else if size32 == 0 {
            moovEnd = result.count
        } else {
            moovEnd = moov.start + Int(size32)
        }
        guard moovEnd <= result.count else {
            throw MetadataTagKitError.corruptFile("moov extends beyond data end")
        }
        try walk(&result, from: moov.start, to: moovEnd, originalMoovEnd: originalMoovEnd, delta: delta)
        return result
    }

    private static func walk(_ data: inout Data, from start: Int, to end: Int, originalMoovEnd: Int, delta: Int64) throws {
        var cursor = start
        while cursor < end {
            let box = try MP4BoxReader.readBox(data, at: cursor, end: end)
            switch box.type {
            case "stco":
                try adjustChunkOffsets32(&data, box: box, originalMoovEnd: originalMoovEnd, delta: delta)
            case "co64":
                try adjustChunkOffsets64(&data, box: box, originalMoovEnd: originalMoovEnd, delta: delta)
            default:
                if containerTypes.contains(box.type) {
                    let payloadStart = box.type == "meta" ? box.payloadStart + 4 : box.payloadStart
                    if payloadStart <= box.start + box.size {
                        try walk(&data, from: payloadStart, to: box.start + box.size, originalMoovEnd: originalMoovEnd, delta: delta)
                    }
                }
            }
            cursor = box.start + box.size
        }
    }

    private static func adjustChunkOffsets32(_ data: inout Data, box: MP4BoxReader.Box, originalMoovEnd: Int, delta: Int64) throws {
        guard box.size >= 16 else {
            throw MetadataTagKitError.corruptFile("stco box too small")
        }
        let entryCount = Int(MP4BoxReader.readUInt32BE(data, at: box.payloadStart + 4))
        let entriesStart = box.payloadStart + 8
        let boxEnd = box.start + box.size
        guard entriesStart + entryCount * 4 <= boxEnd else {
            throw MetadataTagKitError.corruptFile("stco entry count exceeds box size")
        }
        let wrap = UInt32(truncatingIfNeeded: delta)
        for index in 0..<entryCount {
            let offset = entriesStart + index * 4
            let entry = Int(MP4BoxReader.readUInt32BE(data, at: offset))
            // Only chunk offsets that point after the original moov box shift when moov is
            // rebuilt in place; in a moov-after-mdat layout the chunks stay put.
            guard entry >= originalMoovEnd else { continue }
            let adjusted = MP4BoxReader.readUInt32BE(data, at: offset) &+ wrap
            data.replaceSubrange(offset..<(offset + 4), with: MP4BoxWriter.uInt32BE(adjusted))
        }
    }

    private static func adjustChunkOffsets64(_ data: inout Data, box: MP4BoxReader.Box, originalMoovEnd: Int, delta: Int64) throws {
        guard box.size >= 16 else {
            throw MetadataTagKitError.corruptFile("co64 box too small")
        }
        let entryCount = Int(MP4BoxReader.readUInt32BE(data, at: box.payloadStart + 4))
        let entriesStart = box.payloadStart + 8
        let boxEnd = box.start + box.size
        guard entriesStart + entryCount * 8 <= boxEnd else {
            throw MetadataTagKitError.corruptFile("co64 entry count exceeds box size")
        }
        let wrap = UInt64(truncatingIfNeeded: delta)
        for index in 0..<entryCount {
            let offset = entriesStart + index * 8
            let entry = MP4BoxReader.readUInt64BE(data, at: offset)
            guard entry >= UInt64(originalMoovEnd) else { continue }
            let adjusted = entry &+ wrap
            data.replaceSubrange(offset..<(offset + 8), with: MP4BoxWriter.uInt64BE(adjusted))
        }
    }
}
