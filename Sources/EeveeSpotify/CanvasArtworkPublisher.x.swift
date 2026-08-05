import Foundation
import Orion
import MediaPlayer
import UIKit

struct CanvasPublisherGroup: HookGroup {}

private let canvasVideoSupported: Bool =
    MPNowPlayingInfoCenter.responds(to: Selector(("supportedAnimatedArtworkKeys")))

private let canvasPublishQueue = DispatchQueue(label: "com.eeveespotify.canvas.publish")
private var _canvasURI: String?
private var _canvasVideoURL: URL?
private var _canvasArtworkBox: AnyObject?
private var _canvasScanStart: Date?
private var _canvasResolving = false
private var _lastScanAttempt: Date = .distantPast

private let canvasScanWindow: TimeInterval = 180
private let canvasScanThrottle: TimeInterval = 5

private var canvasURI: String? {
    get { canvasPublishQueue.sync { _canvasURI } }
    set { canvasPublishQueue.sync { _canvasURI = newValue } }
}
private var canvasVideoURL: URL? {
    get { canvasPublishQueue.sync { _canvasVideoURL } }
    set { canvasPublishQueue.sync { _canvasVideoURL = newValue } }
}
private var canvasArtworkBox: AnyObject? {
    get { canvasPublishQueue.sync { _canvasArtworkBox } }
    set { canvasPublishQueue.sync { _canvasArtworkBox = newValue } }
}
private var canvasScanStart: Date? {
    get { canvasPublishQueue.sync { _canvasScanStart } }
    set { canvasPublishQueue.sync { _canvasScanStart = newValue } }
}
private var canvasResolving: Bool {
    get { canvasPublishQueue.sync { _canvasResolving } }
    set { canvasPublishQueue.sync { _canvasResolving = newValue } }
}
private var lastScanAttempt: Date {
    get { canvasPublishQueue.sync { _lastScanAttempt } }
    set { canvasPublishQueue.sync { _lastScanAttempt = newValue } }
}

private func findCanvasVideoFile(modifiedSince cutoff: Date) -> URL? {
    let fm = FileManager.default
    var roots: [URL] = []
    roots.append(contentsOf: fm.urls(for: .cachesDirectory, in: .userDomainMask))
    roots.append(contentsOf: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask))
    var newest: (mod: Date, url: URL)?
    var inspected = 0
    for root in roots {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { continue }
        while let item = enumerator.nextObject() {
            inspected += 1
            if inspected > 30000 { return newest?.url }
            guard let url = item as? URL else { continue }
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "mp4" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let mod = values.contentModificationDate,
                  mod > cutoff else { continue }
            if newest == nil || mod > newest!.mod {
                newest = (mod, url)
            }
        }
    }
    return newest?.url
}

@available(iOS 19.0, *)
private func makeCanvasArtwork(
    uri: String,
    url: URL,
    staticArtwork: MPMediaItemArtwork?
) -> MPMediaItemAnimatedArtwork {
    MPMediaItemAnimatedArtwork(
        artworkID: uri,
        previewImageRequestHandler: { size in
            staticArtwork?.image(at: size)
        },
        videoAssetFileURLRequestHandler: { _ in
            url
        }
    )
}

private func rebuildCanvasArtwork(for uri: String) {
    guard canvasVideoSupported, let url = canvasVideoURL else { return }
    var staticArtwork: MPMediaItemArtwork?
    if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
       let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
        staticArtwork = art
    }
    if #available(iOS 19.0, *) {
        canvasArtworkBox = makeCanvasArtwork(uri: uri, url: url, staticArtwork: staticArtwork)
        canvasURI = uri
        writeDebugLog("[CANVAS][PUB] built animated artwork uri=\(uri) video=\(url.path) preview=\(staticArtwork != nil)")
    }
}

private func ensureCanvasArtwork(for uri: String) {
    guard canvasVideoSupported else { return }
    if uri != canvasURI {
        canvasURI = uri
        canvasVideoURL = nil
        canvasArtworkBox = nil
        canvasScanStart = Date()
        canvasResolving = false
        writeDebugLog("[CANVAS][PUB] new track uri=\(uri)")
    }
    if canvasArtworkBox != nil { return }
    if let url = canvasVideoURL {
        rebuildCanvasArtwork(for: uri)
        return
    }
    guard let scanStart = canvasScanStart else { return }
    let now = Date()
    guard now.timeIntervalSince(scanStart) < canvasScanWindow else { return }
    guard now.timeIntervalSince(lastScanAttempt) > canvasScanThrottle else { return }
    guard !canvasResolving else { return }
    lastScanAttempt = now
    canvasResolving = true
    DispatchQueue.global(qos: .utility).async {
        let found = findCanvasVideoFile(modifiedSince: scanStart)
        DispatchQueue.main.async {
            canvasResolving = false
            guard uri == canvasURI else { return }
            if let found = found {
                canvasVideoURL = found
                writeDebugLog("[CANVAS][PUB] resolved video \(found.path)")
            }
            if canvasArtworkBox == nil {
                rebuildCanvasArtwork(for: uri)
            }
        }
    }
}

class CanvasNowPlayingInfoCenterHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "MPNowPlayingInfoCenter"

    func setNowPlayingInfo(_ info: [String: Any]?) {
        if #available(iOS 19.0, *) {
            if canvasVideoSupported, let uri = capturedTrackURI {
                ensureCanvasArtwork(for: uri)
                if canvasURI == uri,
                   let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork {
                    var merged = info ?? [:]
                    merged[MPNowPlayingInfoProperty3x4AnimatedArtwork] = artwork
                    orig.setNowPlayingInfo(merged)
                    return
                }
            }
        }
        orig.setNowPlayingInfo(info)
    }
}

func activateCanvasArtworkPublisher() {
    guard canvasVideoSupported else {
        writeDebugLog("[CANVAS][PUB] disabled: supportedAnimatedArtworkKeys unavailable (iOS < 26)")
        return
    }
    CanvasPublisherGroup().activate()
    writeDebugLog("[CANVAS][PUB] activated (iOS 26 animated artwork publisher)")
}
