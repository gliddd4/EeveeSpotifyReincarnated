import XCTest
@testable import MetadataTagKit

class TagEditorTests: XCTestCase {
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
            .appendingPathComponent("TagEditorTests-\(UUID().uuidString)")
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

    private func audioRegion(_ data: Data) -> Data? {
        guard let tagSize = id3TagSize(data) else { return nil }
        let start = 10 + tagSize
        guard start <= data.count else { return nil }
        return data.subdata(in: start..<data.count)
    }

    private struct TopLevelBox {
        let type: String
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
            boxes.append(TopLevelBox(type: type, payload: data.subdata(in: offset + headerSize..<offset + boxSize)))
            offset += boxSize
        }
        return boxes
    }

    private func mdatPayload(in data: Data) -> Data? {
        return topLevelBoxes(in: data).first { $0.type == "mdat" }?.payload
    }

    private struct ChunkOffsets {
        let stco: [UInt32]
        let co64: [UInt64]
    }

    private func chunkOffsets(in data: Data) -> ChunkOffsets {
        var stco: [UInt32] = []
        var co64: [UInt64] = []
        func walkBoxes(from start: Int, to end: Int) {
            var offset = start
            while offset + 8 <= end {
                let size32 = uint32(data, at: offset)
                let type = String(data: data.subdata(in: offset + 4..<offset + 8), encoding: .ascii) ?? ""
                var boxSize = Int(size32)
                var headerSize = 8
                if size32 == 1 {
                    guard offset + 16 <= end else { return }
                    boxSize = Int(uint64(data, at: offset + 8))
                    headerSize = 16
                } else if size32 == 0 {
                    boxSize = end - offset
                }
                guard boxSize >= headerSize, offset + boxSize <= end else { return }
                let payloadStart = offset + headerSize
                if type == "stco" {
                    let count = Int(uint32(data, at: payloadStart + 4))
                    for i in 0..<count {
                        stco.append(uint32(data, at: payloadStart + 8 + i * 4))
                    }
                } else if type == "co64" {
                    let count = Int(uint32(data, at: payloadStart + 4))
                    for i in 0..<count {
                        co64.append(uint64(data, at: payloadStart + 8 + i * 8))
                    }
                } else if type == "moov" || type == "trak" || type == "mdia" || type == "minf" || type == "stbl" {
                    walkBoxes(from: payloadStart, to: offset + boxSize)
                } else if type == "meta" {
                    walkBoxes(from: payloadStart + 4, to: offset + boxSize)
                }
                offset += boxSize
            }
        }
        walkBoxes(from: 0, to: data.count)
        return ChunkOffsets(stco: stco, co64: co64)
    }

    func testReadMP3Tagged() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_tagged", "mp3", into: dir)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.title, "Original Title")
        XCTAssertEqual(metadata.artist, "Original Artist")
        XCTAssertEqual(metadata.album, "Original Album")
    }

    func testReadMP3Untagged() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_untagged", "mp3", into: dir)
        let metadata = try TagEditor.read(from: file)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.artwork)
    }

    func testWriteMP3AllFields() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_untagged", "mp3", into: dir)
        try TagEditor.write(TrackMetadata(title: "New Title", artist: "New Artist", album: "New Album"), to: file)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.title, "New Title")
        XCTAssertEqual(metadata.artist, "New Artist")
        XCTAssertEqual(metadata.album, "New Album")
        XCTAssertNil(metadata.artwork)
    }

    func testMP3AudioIdenticalAfterWrite() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_tagged", "mp3", into: dir)
        let oldData = try Data(contentsOf: file)
        try TagEditor.write(TrackMetadata(title: "New Title"), to: file)
        let newData = try Data(contentsOf: file)
        let oldAudio = try XCTUnwrap(audioRegion(oldData))
        let newAudio = try XCTUnwrap(audioRegion(newData))
        XCTAssertEqual(oldAudio, newAudio)
    }

    func testMP3PreservesUneditedFields() throws {
        let dir = makeTempDir()
        let file = try copyFixture("mp3_tagged", "mp3", into: dir)
        try TagEditor.write(TrackMetadata(artist: "New Artist"), to: file)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.artist, "New Artist")
        XCTAssertEqual(metadata.title, "Original Title")
        XCTAssertEqual(metadata.album, "Original Album")
    }

    func testMP3CoverWriteAndRead() throws {
        let cover = try fixtureData("cover", "png")
        let taggedDir = makeTempDir()
        let tagged = try copyFixture("mp3_tagged", "mp3", into: taggedDir)
        try TagEditor.write(TrackMetadata(artwork: cover), to: tagged)
        XCTAssertEqual(try TagEditor.read(from: tagged).artwork, cover)

        let untaggedDir = makeTempDir()
        let untagged = try copyFixture("mp3_untagged", "mp3", into: untaggedDir)
        try TagEditor.write(TrackMetadata(artwork: cover), to: untagged)
        XCTAssertEqual(try TagEditor.read(from: untagged).artwork, cover)
    }

    func testReadM4ATagged() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_tagged", "m4a", into: dir)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.title, "Original Title")
        XCTAssertEqual(metadata.artist, "Original Artist")
        XCTAssertEqual(metadata.album, "Original Album")
    }

    func testReadM4AUntagged() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_untagged", "m4a", into: dir)
        let metadata = try TagEditor.read(from: file)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.artwork)
    }

    func testWriteM4AAllFields() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_untagged", "m4a", into: dir)
        try TagEditor.write(TrackMetadata(title: "New Title", artist: "New Artist", album: "New Album"), to: file)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.title, "New Title")
        XCTAssertEqual(metadata.artist, "New Artist")
        XCTAssertEqual(metadata.album, "New Album")
    }

    func testM4AAudioIdenticalAfterWrite() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_tagged", "m4a", into: dir)
        let oldData = try Data(contentsOf: file)
        let oldOffsets = chunkOffsets(in: oldData)
        try TagEditor.write(TrackMetadata(title: "New Title"), to: file)
        let newData = try Data(contentsOf: file)
        let newOffsets = chunkOffsets(in: newData)

        let oldPayload = try XCTUnwrap(mdatPayload(in: oldData))
        let newPayload = try XCTUnwrap(mdatPayload(in: newData))
        XCTAssertEqual(oldPayload, newPayload)

        // The fixture is a moov-after-mdat layout: chunk offsets point into the
        // (unmoved) mdat, so they must be unchanged after the edit.
        XCTAssertEqual(newOffsets.stco, oldOffsets.stco, "stco chunk offsets must not shift in a moov-after-mdat layout")
        XCTAssertEqual(newOffsets.co64, oldOffsets.co64, "co64 chunk offsets must not shift in a moov-after-mdat layout")
        XCTAssertFalse(newOffsets.stco.isEmpty && newOffsets.co64.isEmpty, "fixture should carry stco or co64 chunk offsets")

        let newBoxes = topLevelBoxes(in: newData)
        XCTAssertFalse(newBoxes.isEmpty)
        XCTAssertTrue(newBoxes.contains { $0.type == "mdat" })
    }

    func testM4APreservesUneditedFields() throws {
        let dir = makeTempDir()
        let file = try copyFixture("m4a_tagged", "m4a", into: dir)
        try TagEditor.write(TrackMetadata(artist: "New Artist"), to: file)
        let metadata = try TagEditor.read(from: file)
        XCTAssertEqual(metadata.artist, "New Artist")
        XCTAssertEqual(metadata.title, "Original Title")
        XCTAssertEqual(metadata.album, "Original Album")
    }

    func testM4ACoverWriteAndRead() throws {
        let cover = try fixtureData("cover", "png")
        let taggedDir = makeTempDir()
        let tagged = try copyFixture("m4a_tagged", "m4a", into: taggedDir)
        try TagEditor.write(TrackMetadata(artwork: cover), to: tagged)
        XCTAssertEqual(try TagEditor.read(from: tagged).artwork, cover)

        let untaggedDir = makeTempDir()
        let untagged = try copyFixture("m4a_untagged", "m4a", into: untaggedDir)
        try TagEditor.write(TrackMetadata(artwork: cover), to: untagged)
        XCTAssertEqual(try TagEditor.read(from: untagged).artwork, cover)
    }

    func testUnsupportedFormatThrows() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("unknown-\(UUID().uuidString).bin")
        try Data(repeating: 0xAA, count: 100).write(to: file)
        XCTAssertThrowsError(try TagEditor.write(TrackMetadata(title: "X"), to: file)) { error in
            XCTAssertEqual(error as? MetadataTagKitError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try TagEditor.read(from: file)) { error in
            XCTAssertEqual(error as? MetadataTagKitError, .unsupportedFormat)
        }
    }

    func testRoundTripStability() throws {
        let dir = makeTempDir()
        let mp3 = try copyFixture("mp3_tagged", "mp3", into: dir)
        try TagEditor.write(TrackMetadata(title: "X"), to: mp3)
        try TagEditor.write(TrackMetadata(title: "Y"), to: mp3)
        XCTAssertEqual(try TagEditor.read(from: mp3).title, "Y")

        let m4a = try copyFixture("m4a_tagged", "m4a", into: dir)
        try TagEditor.write(TrackMetadata(title: "X"), to: m4a)
        try TagEditor.write(TrackMetadata(title: "Y"), to: m4a)
        XCTAssertEqual(try TagEditor.read(from: m4a).title, "Y")
    }
}
