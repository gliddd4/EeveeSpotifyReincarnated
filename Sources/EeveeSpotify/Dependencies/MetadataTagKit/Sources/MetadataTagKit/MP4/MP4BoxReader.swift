import Foundation

internal enum MP4BoxReader {
    struct Box {
        let type: String
        let start: Int
        let headerSize: Int
        let payloadStart: Int
        let size: Int
    }

    static func readBoxes(_ data: Data, at offset: Int, end: Int) throws -> [Box] {
        var boxes: [Box] = []
        var cursor = offset
        while cursor < end {
            let box = try readBox(data, at: cursor, end: end)
            boxes.append(box)
            cursor = box.start + box.size
        }
        return boxes
    }

    static func findChild(_ data: Data, parent: Box, type: String) throws -> Box? {
        // A meta box begins its payload with a 4-byte version/flags field before its child boxes.
        let payloadStart = parent.type == "meta" ? parent.payloadStart + 4 : parent.payloadStart
        guard payloadStart <= parent.start + parent.size else { return nil }
        let children = try readBoxes(data, at: payloadStart, end: parent.start + parent.size)
        return children.first { $0.type == type }
    }

    static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(data[offset]) << 56
            | UInt64(data[offset + 1]) << 48
            | UInt64(data[offset + 2]) << 40
            | UInt64(data[offset + 3]) << 32
            | UInt64(data[offset + 4]) << 24
            | UInt64(data[offset + 5]) << 16
            | UInt64(data[offset + 6]) << 8
            | UInt64(data[offset + 7])
    }

    static func readBox(_ data: Data, at offset: Int, end: Int) throws -> Box {
        guard offset + 8 <= end else {
            throw MetadataTagKitError.corruptFile("truncated box header at offset \(offset)")
        }
        let size32 = readUInt32BE(data, at: offset)
        let type = String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .isoLatin1) ?? "????"
        var headerSize = 8
        var size: Int
        if size32 == 1 {
            guard offset + 16 <= end else {
                throw MetadataTagKitError.corruptFile("truncated 64-bit box header at offset \(offset)")
            }
            let largeSize = readUInt64BE(data, at: offset + 8)
            guard largeSize >= 16, largeSize <= UInt64(Int.max) else {
                throw MetadataTagKitError.corruptFile("invalid 64-bit box size at offset \(offset)")
            }
            headerSize = 16
            size = Int(largeSize)
        } else if size32 == 0 {
            size = end - offset
        } else {
            size = Int(size32)
        }
        guard size >= headerSize else {
            throw MetadataTagKitError.corruptFile("box '\(type)' at offset \(offset) has invalid size \(size)")
        }
        guard offset + size <= end else {
            throw MetadataTagKitError.corruptFile("box '\(type)' at offset \(offset) extends beyond region end")
        }
        return Box(type: type, start: offset, headerSize: headerSize, payloadStart: offset + headerSize, size: size)
    }
}
