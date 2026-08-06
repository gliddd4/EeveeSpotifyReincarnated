import Foundation
import MetadataTagKit

let arguments = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printUsage(to stderr: Bool = false) {
    let text = """
    usage: metadata-edit <command> [file] [options]

    commands:
      dump <file>                          print present metadata fields
      set <file> [options]                 write metadata fields

    set options:
      --title <value>      set the title
      --artist <value>     set the artist
      --album <value>      set the album
      --artwork <path>     set the artwork image

    global options:
      --help, -h           show this help

    """
    if stderr {
        FileHandle.standardError.write(Data(text.utf8))
    } else {
        print(text, terminator: "")
    }
}

let knownFlags: Set<String> = ["--title", "--artist", "--album", "--artwork", "--help", "-h"]

func value(for flag: String, at index: Int) -> String {
    guard index + 1 < arguments.count else {
        fail("missing value for \(flag)")
    }
    let candidate = arguments[index + 1]
    if knownFlags.contains(candidate) {
        fail("missing value for \(flag)")
    }
    return candidate
}

guard arguments.count >= 2 else {
    printUsage(to: true)
    exit(1)
}

let command = arguments[1]

if command == "--help" || command == "-h" {
    printUsage()
    exit(0)
}

func printMetadata(_ metadata: TrackMetadata) {
    if let title = metadata.title {
        print("title: \(title)")
    }
    if let artist = metadata.artist {
        print("artist: \(artist)")
    }
    if let album = metadata.album {
        print("album: \(album)")
    }
    if let artwork = metadata.artwork {
        print("artwork: \(artwork.count) bytes")
    }
}

switch command {
case "dump":
    guard arguments.count >= 3 else {
        fail("missing file argument")
    }
    let url = URL(fileURLWithPath: arguments[2])
    do {
        let data = try Data(contentsOf: url)
        switch FormatDetector.detect(data) {
        case .mp3:
            print("format: mp3")
        case .m4a:
            print("format: m4a")
        case .unsupported:
            fail("unsupported format")
        }
        let metadata = try TagEditor.read(from: url)
        printMetadata(metadata)
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }

case "set":
    guard arguments.count >= 3 else {
        fail("missing file argument")
    }
    let url = URL(fileURLWithPath: arguments[2])
    var title: String?
    var artist: String?
    var album: String?
    var artwork: Data?

    var index = 3
    while index < arguments.count {
        switch arguments[index] {
        case "--title":
            title = value(for: "--title", at: index)
            index += 2
        case "--artist":
            artist = value(for: "--artist", at: index)
            index += 2
        case "--album":
            album = value(for: "--album", at: index)
            index += 2
        case "--artwork":
            let imageURL = URL(fileURLWithPath: value(for: "--artwork", at: index))
            do {
                artwork = try Data(contentsOf: imageURL)
            } catch {
                fail(error.localizedDescription)
            }
            index += 2
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            fail("unknown option: \(arguments[index])")
        }
    }

    let edits = TrackMetadata(title: title, artist: artist, album: album, artwork: artwork)
    do {
        try TagEditor.write(edits, to: url)
        print("ok")
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }

default:
    fail("unknown command: \(command)")
}
