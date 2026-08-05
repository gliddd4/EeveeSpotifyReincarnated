import XCTest
@testable import MetadataTagKit

class EdgeCaseTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeCaseTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func copyFixture(_ name: String, _ ext: String, into dir: URL) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        let dest = dir.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private func fixtureData(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[offset + i])
        }
        return value
    }

    private func uint64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private func id3TagSize(_ data: Data) -> Int? {
        guard data.count > 10, data.starts(with: Data("ID3".utf8)) else { return nil }
        let b = [UInt8](data[6...9])
        return (Int(b[0] & 0x7F) << 21) | (Int(b[1] & 0x7F) << 14) | (Int(b[2] & 0x7F) << 7) | Int(b[3] & 0x7F)
    }

    // The audio region is everything after the ID3 tag; a file with no ID3 tag is all audio.
    private func mp3AudioRegion(_ data: Data) -> Data? {
        guard let tagSize = id3TagSize(data) else { return data }
        let start = 10 + tagSize
        guard start <= data.count else { return nil }
        return data.subdata(in: start..<data.count)
    }

    private struct TopLevelBox {
        let type: String
        let start: Int
        let size: Int
        let headerSize: Int
        let payload: Data
    }

    private func topLevelBoxes(in data: Data) -> [TopLevelBox] {
        var boxes: [TopLevelBox] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = uint32(data, at: offset)
            let type = String(data: data.subdata(in: offset + 4..<offset + 8), encoding: .ascii) ?? ""
            var boxSize = Int(size32)
            var headerSize = 8
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                boxSize = Int(uint64(data, at: offset + 8))
                headerSize = 16
            } else if size32 == 0 {
                boxSize = data.count - offset
            }
            guard boxSize >= headerSize, offset + boxSize <= data.count else { break }
            boxes.append(TopLevelBox(
                type: type,
                start: offset,
                size: boxSize,
                headerSize: headerSize,
                payload: data.subdata(in: offset + headerSize..<offset + boxSize)
            ))
            offset += boxSize
        }
        return boxes
    }

    private func mdatPayload(in data: Data) -> Data? {
        return topLevelBoxes(in: data).first { $0.type == "mdat" }?.payload
    }

    // Builds a bare ID3v2.3 header whose synchsafe size field claims `tagSize` bytes.
    private func id3Blob(version: UInt8, tagSize: Int) -> Data {
        var data = Data("ID3".utf8)
        data.append(version)
        data.append(0)
        data.append(0)
        data.append(contentsOf: [
            UInt8((tagSize >> 21) & 0x7F),
            UInt8((tagSize >> 14) & 0x7F),
            UInt8((tagSize >> 7) & 0x7F),
            UInt8(tagSize & 0x7F),
        ])
        return data
    }

    func testUnicodeRoundTrip() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_utf8", "mp3", into: dir)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.title, "UTF16 Title")
        XCTAssertEqual(metadata.artist, "Ünïcode Ärtist")
        XCTAssertEqual(metadata.album, "Álbum")

        let japaneseArtist = "新しいアーティスト"
        try TagEditor.write(TrackMetadata(artist: japaneseArtist), to: file)
        let roundTripped = try TagEditor.read(from: file)
        XCTAssertEqual(roundTripped.artist, japaneseArtist)
        XCTAssertEqual(roundTripped.title, "UTF16 Title")
        XCTAssertEqual(roundTripped.album, "Álbum")
    }

    func testJPEGCover() throws {
        let jpeg = try fixtureData("cover", "jpg")

        let mp3Dir = makeTempDir()
        let mp3 = try copyFixture("mp3_tagged", "mp3", into: mp3Dir)
        try TagEditor.write(TrackMetadata(artwork: jpeg), to: mp3)
        XCTAssertEqual(try TagEditor.read(from: mp3).artwork, jpeg)

        let m4aDir = makeTempDir()
        let m4a = try copyFixture("m4a_tagged", "m4a", into: m4aDir)
        try TagEditor.write(TrackMetadata(artwork: jpeg), to: m4a)
        XCTAssertEqual(try TagEditor.read(from: m4a).artwork, jpeg)
    }

    func testMoovFirstChunkOffsetsShift() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_tagged_moovfirst", "m4a", into: dir)
        let oldData = try Data(contentsOf: file)
        let oldBoxes = topLevelBoxes(in: oldData)
        let oldMdat = try XCTUnwrap(oldBoxes.first { $0.type == "mdat" })
        let oldMoov = try XCTUnwrap(oldBoxes.first { $0.type == "moov" })
        let oldMdatStart = oldMdat.start
        let oldMdatPayload = oldMdat.payload

        try TagEditor.write(TrackMetadata(title: "Longer Title That Grows The Tag"), to: file)

        let newData = try Data(contentsOf: file)
        let newBoxes = topLevelBoxes(in: newData)
        let newMdat = try XCTUnwrap(newBoxes.first { $0.type == "mdat" })
        let newMoov = try XCTUnwrap(newBoxes.first { $0.type == "moov" })

        XCTAssertEqual(newMdat.payload, oldMdatPayload, "mdat payload must be byte-identical after a growing moov edit")
        XCTAssertGreaterThan(newMoov.size, oldMoov.size, "the longer title must grow the moov box")
        XCTAssertEqual(newMdat.start - oldMdatStart, newMoov.size - oldMoov.size, "mdat must shift by exactly the moov growth in a moov-first layout")
        XCTAssertGreaterThanOrEqual(newMoov.size, newMoov.headerSize)
        XCTAssertTrue(newBoxes.contains { $0.type == "moov" })
        XCTAssertTrue(newBoxes.contains { $0.type == "mdat" })
    }

    func testWriteEmptyEditsNoOp() throws {
        let mp3Dir = makeTempDir()
        let mp3 = try copyFixture("mp3_tagged", "mp3", into: mp3Dir)
        let mp3Old = try Data(contentsOf: mp3)
        try TagEditor.write(TrackMetadata(), to: mp3)
        XCTAssertEqual(try Data(contentsOf: mp3), mp3Old, "empty-edits write to mp3 must not rewrite the file")

        let m4aDir = makeTempDir()
        let m4a = try copyFixture("m4a_tagged", "m4a", into: m4aDir)
        let m4aOld = try Data(contentsOf: m4a)
        try TagEditor.write(TrackMetadata(), to: m4a)
        XCTAssertEqual(try Data(contentsOf: m4a), m4aOld, "empty-edits write to m4a must not rewrite the file")
    }

    func testZeroByteFileThrows() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("empty-\(UUID().uuidString).bin")
        try Data().write(to: file)
        XCTAssertThrowsError(try TagEditor.read(from: file))
        XCTAssertThrowsError(try TagEditor.write(TrackMetadata(title: "X"), to: file))
    }

    func testTruncatedID3ThrowsCorruptTag() throws {
        let dir = makeTempDir()

        let truncated = id3Blob(version: 3, tagSize: 5)
        let truncatedFile = dir.appendingPathComponent("truncated-\(UUID().uuidString).mp3")
        try truncated.write(to: truncatedFile)
        XCTAssertThrowsError(try TagEditor.read(from: truncatedFile)) { error in
            guard case MetadataTagKitError.corruptTag = error else {
                return XCTFail("expected corruptTag, got \(error)")
            }
        }

        let empty = id3Blob(version: 3, tagSize: 0)
        let emptyFile = dir.appendingPathComponent("empty-tag-\(UUID().uuidString).mp3")
        try empty.write(to: emptyFile)
        let metadata = try TagEditor.read(from: emptyFile)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.artwork)
    }

    func testCorruptFrameSizeThrowsNotCrash() throws {
        var blob = id3Blob(version: 3, tagSize: 10)
        blob.append(contentsOf: Data("TIT2".utf8))
        blob.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        blob.append(contentsOf: [0x00, 0x00])

        let dir = makeTempDir()
        let file = dir.appendingPathComponent("corrupt-frame-\(UUID().uuidString).mp3")
        try blob.write(to: file)
        XCTAssertThrowsError(try TagEditor.read(from: file)) { error in
            guard case MetadataTagKitError.corruptTag = error else {
                return XCTFail("expected corruptTag, got \(error)")
            }
        }
    }

    func testAudioRegionPreservedForAllWrites() throws {
        let png = try fixtureData("cover", "png")
        let edits = TrackMetadata(title: "X", artist: "Y", album: "Z", artwork: png)

        for name in ["mp3_untagged", "mp3_tagged", "mp3_utf8"] {
            let dir = makeTempDir()
            let file = try copyFixture(name, "mp3", into: dir)
            let old = try Data(contentsOf: file)
            try TagEditor.write(edits, to: file)
            let new = try Data(contentsOf: file)
            let oldAudio = try XCTUnwrap(mp3AudioRegion(old), "\(name): could not locate mp3 audio region in old data")
            let newAudio = try XCTUnwrap(mp3AudioRegion(new), "\(name): could not locate mp3 audio region in new data")
            XCTAssertEqual(newAudio, oldAudio, "\(name): mp3 audio bytes changed after write")
        }

        for name in ["m4a_untagged", "m4a_tagged", "m4a_tagged_moovfirst"] {
            let dir = makeTempDir()
            let file = try copyFixture(name, "m4a", into: dir)
            let old = try Data(contentsOf: file)
            try TagEditor.write(edits, to: file)
            let new = try Data(contentsOf: file)
            let oldPayload = try XCTUnwrap(mdatPayload(in: old), "\(name): could not locate mdat in old data")
            let newPayload = try XCTUnwrap(mdatPayload(in: new), "\(name): could not locate mdat in new data")
            XCTAssertEqual(newPayload, oldPayload, "\(name): mdat payload changed after write")
        }
    }

    func testSequentialCoverReplacement() throws {
        let png = try fixtureData("cover", "png")
        let jpg = try fixtureData("cover", "jpg")

        let mp3Dir = makeTempDir()
        let mp3 = try copyFixture("mp3_tagged", "mp3", into: mp3Dir)
        try TagEditor.write(TrackMetadata(artwork: png), to: mp3)
        try TagEditor.write(TrackMetadata(artwork: jpg), to: mp3)
        XCTAssertEqual(try TagEditor.read(from: mp3).artwork, jpg, "last mp3 cover write must win")

        let m4aDir = makeTempDir()
        let m4a = try copyFixture("m4a_tagged", "m4a", into: m4aDir)
        try TagEditor.write(TrackMetadata(artwork: png), to: m4a)
        try TagEditor.write(TrackMetadata(artwork: jpg), to: m4a)
        XCTAssertEqual(try TagEditor.read(from: m4a).artwork, jpg, "last m4a cover write must win")
    }

    func testReadDoesNotTouchFile() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_tagged", "mp3", into: dir)
        let old = try Data(contentsOf: file)
        _ = try TagEditor.read(from: file)
        XCTAssertEqual(try Data(contentsOf: file), old, "read must be side-effect free")
    }
}
