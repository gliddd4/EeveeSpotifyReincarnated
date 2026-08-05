import Foundation

public enum M4AIlstEditor {
    private static let titleType = "©nam"
    private static let artistType = "©ART"
    private static let albumType = "©alb"
    private static let coverType = "covr"
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public static func readMetadata(from data: Data) throws -> TrackMetadata {
        let topLevel = try MP4BoxReader.readBoxes(data, at: 0, end: data.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
            return TrackMetadata()
        }
        guard let udta = try MP4BoxReader.findChild(data, parent: moov, type: "udta"),
              let meta = try MP4BoxReader.findChild(data, parent: udta, type: "meta"),
              let ilst = try MP4BoxReader.findChild(data, parent: meta, type: "ilst") else {
            return TrackMetadata()
        }
        var title: String?
        var artist: String?
        var album: String?
        var artwork: Data?
        let items = try MP4BoxReader.readBoxes(data, at: ilst.payloadStart, end: ilst.start + ilst.size)
        for item in items {
            guard let dataBox = try MP4BoxReader.findChild(data, parent: item, type: "data"),
                  dataBox.size >= 16 else {
                continue
            }
            let indicator = MP4BoxReader.readUInt32BE(data, at: dataBox.payloadStart)
            let payload = data.subdata(in: (dataBox.payloadStart + 8)..<(dataBox.start + dataBox.size))
            switch item.type {
            case titleType:
                if indicator == 1, title == nil { title = String(data: payload, encoding: .utf8) }
            case artistType:
                if indicator == 1, artist == nil { artist = String(data: payload, encoding: .utf8) }
            case albumType:
                if indicator == 1, album == nil { album = String(data: payload, encoding: .utf8) }
            case coverType:
                if (indicator == 13 || indicator == 14), artwork == nil { artwork = payload }
            default:
                break
            }
        }
        return TrackMetadata(title: title, artist: artist, album: album, artwork: artwork)
    }

    public static func write(_ edits: TrackMetadata, to data: Data) throws -> Data {
        let topLevel = try MP4BoxReader.readBoxes(data, at: 0, end: data.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }) else {
            throw MetadataTagKitError.unsupportedFormat
        }
        if edits.title == nil, edits.artist == nil, edits.album == nil, edits.artwork == nil {
            return data
        }
        let newMoov = MP4BoxWriter.box(type: "moov", payload: try rebuildMoovPayload(data: data, moov: moov, edits: edits))
        let originalMoovEnd = moov.start + moov.size
        let delta = Int64(newMoov.count) - Int64(moov.size)
        var out = Data()
        for box in topLevel {
            if box.type == "moov" && box.start == moov.start {
                out.append(newMoov)
            } else {
                out.append(data.subdata(in: box.start..<(box.start + box.size)))
            }
        }
        let moovInOut = MP4BoxReader.Box(type: "moov", start: moov.start, headerSize: 8, payloadStart: moov.start + 8, size: newMoov.count)
        return try M4AChunkOffsetRebuilder.rebuild(out, moov: moovInOut, originalMoovEnd: originalMoovEnd, delta: delta)
    }

    private static func rebuildMoovPayload(data: Data, moov: MP4BoxReader.Box, edits: TrackMetadata) throws -> Data {
        let children = try MP4BoxReader.readBoxes(data, at: moov.payloadStart, end: moov.start + moov.size)
        var payload = Data()
        var hadUdta = false
        for child in children {
            if child.type == "udta" {
                payload.append(try rebuildUdta(data: data, udta: child, edits: edits))
                hadUdta = true
            } else {
                payload.append(data.subdata(in: child.start..<(child.start + child.size)))
            }
        }
        if !hadUdta {
            payload.append(try makeNewUdta(edits: edits))
        }
        return payload
    }

    private static func rebuildUdta(data: Data, udta: MP4BoxReader.Box, edits: TrackMetadata) throws -> Data {
        let children = try MP4BoxReader.readBoxes(data, at: udta.payloadStart, end: udta.start + udta.size)
        var payload = Data()
        var hadMeta = false
        for child in children {
            if child.type == "meta" {
                payload.append(try rebuildMeta(data: data, meta: child, edits: edits))
                hadMeta = true
            } else {
                payload.append(data.subdata(in: child.start..<(child.start + child.size)))
            }
        }
        if !hadMeta {
            payload.append(try makeNewMeta(edits: edits))
        }
        return MP4BoxWriter.box(type: "udta", payload: payload)
    }

    private static func rebuildMeta(data: Data, meta: MP4BoxReader.Box, edits: TrackMetadata) throws -> Data {
        guard meta.size >= 12 else {
            return try makeNewMeta(edits: edits)
        }
        var payload = Data()
        payload.append(data.subdata(in: meta.payloadStart..<(meta.payloadStart + 4)))
        let children = try MP4BoxReader.readBoxes(data, at: meta.payloadStart + 4, end: meta.start + meta.size)
        var hadIlst = false
        for child in children {
            if child.type == "ilst" {
                payload.append(MP4BoxWriter.box(type: "ilst", payload: try makeIlst(edits: edits, existingItems: data.subdata(in: child.payloadStart..<(child.start + child.size)))))
                hadIlst = true
            } else {
                payload.append(data.subdata(in: child.start..<(child.start + child.size)))
            }
        }
        if !hadIlst {
            payload.append(MP4BoxWriter.box(type: "ilst", payload: try makeIlst(edits: edits, existingItems: nil)))
        }
        return MP4BoxWriter.box(type: "meta", payload: payload)
    }

    private static func makeIlst(edits: TrackMetadata, existingItems: Data?) throws -> Data {
        var out = Data()
        var appendedTypes = Set<String>()
        if let existingItems = existingItems {
            let items = try MP4BoxReader.readBoxes(existingItems, at: 0, end: existingItems.count)
            for item in items {
                if appendedTypes.contains(item.type) {
                    continue
                }
                if let replacement = replacementItem(for: item.type, edits: edits) {
                    out.append(replacement)
                    appendedTypes.insert(item.type)
                } else {
                    out.append(existingItems.subdata(in: item.start..<(item.start + item.size)))
                }
            }
        }
        for type in [titleType, artistType, albumType, coverType] {
            if !appendedTypes.contains(type), let replacement = replacementItem(for: type, edits: edits) {
                out.append(replacement)
            }
        }
        return out
    }

    private static func replacementItem(for type: String, edits: TrackMetadata) -> Data? {
        switch type {
        case titleType:
            guard let value = edits.title else { return nil }
            return MP4BoxWriter.box(type: type, payload: MP4BoxWriter.dataBox(typeIndicator: 1, payload: Data(value.utf8)))
        case artistType:
            guard let value = edits.artist else { return nil }
            return MP4BoxWriter.box(type: type, payload: MP4BoxWriter.dataBox(typeIndicator: 1, payload: Data(value.utf8)))
        case albumType:
            guard let value = edits.album else { return nil }
            return MP4BoxWriter.box(type: type, payload: MP4BoxWriter.dataBox(typeIndicator: 1, payload: Data(value.utf8)))
        case coverType:
            guard let artwork = edits.artwork else { return nil }
            return MP4BoxWriter.box(type: type, payload: MP4BoxWriter.dataBox(typeIndicator: imageTypeIndicator(for: artwork), payload: artwork))
        default:
            return nil
        }
    }

    private static func imageTypeIndicator(for data: Data) -> UInt32 {
        if data.count >= pngSignature.count, data.starts(with: pngSignature) {
            return 14
        }
        return 13
    }

    private static func makeNewUdta(edits: TrackMetadata) throws -> Data {
        MP4BoxWriter.box(type: "udta", payload: try makeNewMeta(edits: edits))
    }

    private static func makeNewMeta(edits: TrackMetadata) throws -> Data {
        var payload = Data()
        payload.append(MP4BoxWriter.uInt32BE(0))
        payload.append(makeHdlr())
        payload.append(MP4BoxWriter.box(type: "ilst", payload: try makeIlst(edits: edits, existingItems: nil)))
        return MP4BoxWriter.box(type: "meta", payload: payload)
    }

    private static func makeHdlr() -> Data {
        var payload = Data()
        payload.append(MP4BoxWriter.uInt32BE(0))
        payload.append(MP4BoxWriter.uInt32BE(0))
        payload.append(Data("mdir".utf8))
        payload.append(Data(repeating: 0, count: 12))
        payload.append(Data("appl".utf8))
        return MP4BoxWriter.box(type: "hdlr", payload: payload)
    }
}
