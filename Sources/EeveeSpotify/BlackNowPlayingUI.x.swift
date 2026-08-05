import Orion
import UIKit
import QuartzCore
import MediaPlayer

struct BlackNowPlayingUIGroup: HookGroup {}

// Black-cover analysis cache, keyed by the live track's URI. The lyrics and
// header pipelines never read MPNowPlayingInfoCenter for the current track —
// it stays pinned to the first track until the app relaunches. Instead they
// read the live player track (statefulPlayer.currentTrack()), whose
// metadata()["extracted_color"] is refreshed per track. Keying the cache by
// that live URI means a track switch always misses the cache and re-evaluates
// the new cover, so the verdict can never stick to the first album.
private let blackCoverQueue = DispatchQueue(label: "com.eeveespotify.blackcover")
private var _blackCoverURI: String?
private var _blackCoverPixels: [UInt8]?
private var _blackCoverIsMostlyBlack = false

private var blackCoverURI: String? {
    get { blackCoverQueue.sync { _blackCoverURI } }
    set { blackCoverQueue.sync { _blackCoverURI = newValue } }
}

private var blackCoverIsMostlyBlack: Bool {
    get { blackCoverQueue.sync { _blackCoverIsMostlyBlack } }
    set { blackCoverQueue.sync { _blackCoverIsMostlyBlack = newValue } }
}

private var blackCoverPixels: [UInt8]? {
    get { blackCoverQueue.sync { _blackCoverPixels } }
    set { blackCoverQueue.sync { _blackCoverPixels = newValue } }
}

private let blackLuminanceThreshold = 0.2
private let blackPixelRatioThreshold = 0.25

// Relative luminance of a hex color string (#RRGGBB / #RGB). Returns nil for
// unparseable input.
private func hexLuminance(_ hex: String) -> Double? {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&int)
    let r, g, b: UInt64
    switch cleaned.count {
    case 3:
        (r, g, b) = ((int >> 8) * 17, ((int >> 4) & 0xF) * 17, (int & 0xF) * 17)
    case 6, 8:
        (r, g, b) = (int >> 16, (int >> 8) & 0xFF, int & 0xFF)
    default:
        return nil
    }
    return 0.2126 * Double(r) / 255 + 0.7152 * Double(g) / 255 + 0.0722 * Double(b) / 255
}

// The live track's server-side extracted album color, mirroring how the lyrics
// pipeline resolves it (resolvedTrackExtractedColor). This is the canonical
// color source the header/lyrics use and it is refreshed per track, so it can
// never go stale the way MPNowPlayingInfoCenter artwork does.
private func liveTrackExtractedColorHex() -> String? {
    guard let track = statefulPlayer?.currentTrack() else { return nil }
    let nsTrack = track as AnyObject
    let metaSelector = Selector(("metadata"))
    guard nsTrack.responds(to: metaSelector) else { return nil }
    let meta = track.metadata()
    if let hex = meta["extracted_color"], !hex.isEmpty {
        return hex
    }
    let colorSelector = Selector(("extractedColorHex"))
    guard nsTrack.responds(to: colorSelector) else { return nil }
    if let hex = track.extractedColorHex(), !hex.isEmpty {
        return hex
    }
    return nil
}

// Identity of the currently playing track, from the live player state (never
// stale). Falls back to the captured URI for logging/cache keying when the
// player is unavailable.
private func liveTrackURIString() -> String {
    if let uri = statefulPlayer?.currentTrack().flatMap({ ($0.URI() as? NSURL)?.absoluteString }),
       !uri.isEmpty {
        return uri
    }
    if let captured = capturedTrackURI, !captured.isEmpty {
        return captured
    }
    return ""
}

// Sample the album cover into a small fixed-size RGBA buffer so the black
// analysis reads raw pixels instead of relying on CoreImage, which failed
// silently on-device (CIContext with a null working color space rendered
// nothing, leaving a zeroed buffer that read as pure black for every album).
// Returns nil when no artwork is available (e.g. a local file without a
// cover).
private func sampleCoverRGBA(width: Int = 32, height: Int = 32) -> [UInt8]? {
    guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
          let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
          let cover = artwork.image(at: CGSize(width: 64, height: 64)),
          let cgImage = cover.cgImage else {
        return nil
    }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        return nil
    }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

// Fraction of the sampled cover pixels that read as black (relative
// luminance below `blackLuminanceThreshold`). Returns 0 when no artwork is
// available (e.g. local file without a cover).
private func coverBlackPixelRatio(_ pixels: [UInt8]) -> Double {
    let total = pixels.count / 4
    guard total > 0 else { return 0 }

    var dark = 0
    for i in 0..<total {
        let offset = i * 4
        let r = Double(pixels[offset]) / 255.0
        let g = Double(pixels[offset + 1]) / 255.0
        let b = Double(pixels[offset + 2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < blackLuminanceThreshold {
            dark += 1
        }
    }
    return Double(dark) / Double(total)
}

// Mean relative luminance of the sampled cover — a blur-equivalent estimate
// of the artwork's overall darkness. Downscaling to 32x32 already smooths
// out highlights, text and JPEG noise, which is what the removed Gaussian
// blur was for. Returns 1 (light) when no artwork is available so a missing
// cover never forces black on its own.
private func coverMeanLuminance(_ pixels: [UInt8]) -> Double {
    let total = pixels.count / 4
    guard total > 0 else { return 1 }

    var sum = 0.0
    for i in 0..<total {
        let offset = i * 4
        let r = Double(pixels[offset]) / 255.0
        let g = Double(pixels[offset + 1]) / 255.0
        let b = Double(pixels[offset + 2]) / 255.0
        sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    return sum / Double(total)
}

private func shouldForceBlackGradient() -> Bool {
    guard UserDefaults.blackNowPlayingUI else { return false }

    // Primary path: the live track's extracted album color — the same source
    // the header/lyrics use. It is refreshed per track, so a track switch
    // immediately yields the new cover's verdict with no staleness window.
    if let hex = liveTrackExtractedColorHex(), let luminance = hexLuminance(hex) {
        let isMostlyBlack = luminance < blackLuminanceThreshold
        writeDebugLog("[BlackUI] extractedColor=\(hex) lum=\(String(format: "%.2f", luminance)) uri=\(liveTrackURIString()) -> forceBlack=\(isMostlyBlack)")
        return isMostlyBlack
    }

    // Fallback: pixel-sample the now-playing artwork (no extracted color, e.g.
    // local files). The cache is keyed by the live track URI, so a track
    // switch invalidates the previous verdict and re-samples the new cover.
    guard let pixels = sampleCoverRGBA() else {
        writeDebugLog("[BlackUI] no artwork -> forceBlack=false")
        return false
    }

    let uri = liveTrackURIString()
    if blackCoverURI != uri {
        blackCoverURI = uri
        blackCoverPixels = nil
    }

    if blackCoverPixels == pixels {
        return blackCoverIsMostlyBlack
    }

    // A cover reads as "mostly black" when either its overall (blur-equivalent)
    // luminance is dark — this catches uniform dark covers whose anti-aliased
    // edges and JPEG noise hover just above the pixel threshold — or at least
    // a quarter of its pixels are black.
    let ratio = coverBlackPixelRatio(pixels)
    let meanLuminance = coverMeanLuminance(pixels)
    let isMostlyBlack = meanLuminance < blackLuminanceThreshold
        || ratio >= blackPixelRatioThreshold
    blackCoverPixels = pixels
    blackCoverIsMostlyBlack = isMostlyBlack
    writeDebugLog("[BlackUI] cover meanLum=\(String(format: "%.2f", meanLuminance)) blackRatio=\(String(format: "%.2f", ratio)) uri=\(uri) -> forceBlack=\(isMostlyBlack)")
    return isMostlyBlack
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
}

// --- Delayed re-check state ---
// Safety net for the case where the gradient's setColors: fires before the
// live track object is committed: each tick re-evaluates shouldForceBlackGradient()
// (which reads the live track, so it is fresh per call) and flips the gradient
// when the verdict changes. The loop is bounded so a track with no artwork can't
// keep it running forever; any later setColors: with a new track starts a fresh
// loop.
private let gradientRecheckInterval: TimeInterval = 1.5
private let gradientRecheckMaxAttempts = 6

private var gradientRecheckHook: NowPlayingGradientLayerHook?
private var gradientRecheckOriginalColors: [CGColor]?
private var gradientRecheckAppliedBlack = false
private var gradientRecheckAttempt = 0
private var gradientRecheckWorkItem: DispatchWorkItem?

// Never reschedules over a pending work item — setColors: fires on every
// layout/animation tick, and cancelling here would starve the recheck forever.
private func scheduleGradientRecheck() {
    guard gradientRecheckWorkItem == nil else { return }
    let item = DispatchWorkItem { runGradientRecheck() }
    gradientRecheckWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + gradientRecheckInterval, execute: item)
}

private func runGradientRecheck() {
    gradientRecheckWorkItem = nil
    guard let hook = gradientRecheckHook else { return }

    let forceBlack = shouldForceBlackGradient()
    if forceBlack != gradientRecheckAppliedBlack {
        // Verdict flipped — the live track has settled. Apply it and stop
        // watching; the next setColors: starts a fresh loop.
        gradientRecheckAppliedBlack = forceBlack
        let colors = forceBlack
            ? [UIColor.black.cgColor, UIColor.black.cgColor]
            : gradientRecheckOriginalColors
        hook.orig.setColors(colors)
        writeDebugLog("[BlackUI] recheck flipped gradient -> forceBlack=\(forceBlack)")
    } else if gradientRecheckAttempt < gradientRecheckMaxAttempts {
        // Live track may still be settling (or still missing) — try again.
        gradientRecheckAttempt += 1
        scheduleGradientRecheck()
    }
}

// Intercepts every gradient color application in the app, but only overrides
// layers owned by the now-playing gradient views (NowPlaying_ScrollImpl /
// NowPlaying_MixingTransitionImpl.NPVGradientView). Spotify's own colors are
// left untouched for lighter covers, so the gradient reverts to normal on
// track change.
class NowPlayingGradientLayerHook: ClassHook<CAGradientLayer> {
    typealias Group = BlackNowPlayingUIGroup
    static let targetName = "CAGradientLayer"

    func setColors(_ colors: [CGColor]?) {
        if isNowPlayingGradientLayer(target) {
            gradientRecheckHook = self
            gradientRecheckOriginalColors = colors
            gradientRecheckAppliedBlack = shouldForceBlackGradient()
            gradientRecheckAttempt = 0
            scheduleGradientRecheck()
            if gradientRecheckAppliedBlack {
                orig.setColors([UIColor.black.cgColor, UIColor.black.cgColor])
                return
            }
        }
        orig.setColors(colors)
    }
}

func activateBlackNowPlayingUI() {
    guard NSClassFromString("CAGradientLayer") != nil else {
        writeDebugLog("[BlackUI] skipped: CAGradientLayer unavailable")
        return
    }
    BlackNowPlayingUIGroup().activate()
    writeDebugLog("[BlackUI] activated")
}
