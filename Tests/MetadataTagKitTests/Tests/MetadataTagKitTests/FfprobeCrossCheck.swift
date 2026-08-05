import XCTest
@testable import MetadataTagKit

class FfprobeCrossCheck: XCTestCase {
    func testFfprobeVerifiesWrittenTags() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ffprobe-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mp3Src = try XCTUnwrap(Bundle.module.url(forResource: "mp3_tagged", withExtension: "mp3", subdirectory: "Fixtures"))
        let m4aSrc = try XCTUnwrap(Bundle.module.url(forResource: "m4a_tagged", withExtension: "m4a", subdirectory: "Fixtures"))

        let mp3 = tmp.appendingPathComponent("a.mp3")
        let m4a = tmp.appendingPathComponent("a.m4a")
        try FileManager.default.copyItem(at: mp3Src, to: mp3)
        try FileManager.default.copyItem(at: m4aSrc, to: m4a)

        try TagEditor.write(TrackMetadata(title: "Ffprobe Title", artist: "Ffprobe Artist", album: "Ffprobe Album"), to: mp3)
        try TagEditor.write(TrackMetadata(title: "Ffprobe Title", artist: "Ffprobe Artist", album: "Ffprobe Album"), to: m4a)

        func ffprobe(_ url: URL) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffprobe")
            p.arguments = ["-v", "error", "-show_entries", "format_tags=title,artist,album", "-of", "default=noprint_wrappers=1", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        let mp3Out = try ffprobe(mp3)
        print("MP3 FFProbe:\n\(mp3Out)")
        XCTAssertTrue(mp3Out.contains("title=Ffprobe Title"))
        XCTAssertTrue(mp3Out.contains("artist=Ffprobe Artist"))
        XCTAssertTrue(mp3Out.contains("album=Ffprobe Album"))

        let m4aOut = try ffprobe(m4a)
        print("M4A FFProbe:\n\(m4aOut)")
        XCTAssertTrue(m4aOut.contains("title=Ffprobe Title"))
        XCTAssertTrue(m4aOut.contains("artist=Ffprobe Artist"))
        XCTAssertTrue(m4aOut.contains("album=Ffprobe Album"))

        try FileManager.default.copyItem(at: mp3Src, to: tmp.appendingPathComponent("orig.mp3"))
        try FileManager.default.copyItem(at: m4aSrc, to: tmp.appendingPathComponent("orig.m4a"))
        let origMp3 = try ffprobe(tmp.appendingPathComponent("orig.mp3"))
        let origM4a = try ffprobe(tmp.appendingPathComponent("orig.m4a"))
        print("orig mp3: \(origMp3)orig m4a: \(origM4a)")
    }
}
