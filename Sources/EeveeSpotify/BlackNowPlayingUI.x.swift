import Orion
import UIKit
import QuartzCore
import MediaPlayer

struct BlackNowPlayingUIGroup: HookGroup {}

// Black-cover analysis cache, keyed by the captured track URI so a repeated
// setColors: (layout pass, animation tick) reuses the last result instead of
// re-scanning the cover image every time.
private let blackCoverQueue = DispatchQueue(label: "com.eeveespotify.blackcover")
private var _blackCoverURI: String?
private var _blackCoverIsMostlyBlack = false

private var blackCoverIsMostlyBlack: Bool {
    get { blackCoverQueue.sync { _blackCoverIsMostlyBlack } }
    set { blackCoverQueue.sync { _blackCoverIsMostlyBlack = newValue } }
}

private var blackCoverURI: String? {
    get { blackCoverQueue.sync { _blackCoverURI } }
    set { blackCoverQueue.sync { _blackCoverURI = newValue } }
}

private let blackLuminanceThreshold = 0.2
private let blackPixelRatioThreshold = 0.25

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

    // Prefer the viewWillAppear-captured URI; fall back to the player's live
    // track URI so the cache key stays unique even when the scroll-view hook
    // did not fire for this playback path (e.g. Donda-style covers on builds
    // where NPVScrollViewController is absent).
    let uri = capturedTrackURI
        ?? statefulPlayer?.currentTrack().flatMap { ($0.URI() as? NSURL)?.absoluteString }
        ?? ""
    // Only treat an empty URI as a cache key when we have nothing better, and
    // never cache a result under "" — that would freeze one album's verdict
    // for every subsequent album.
    if !uri.isEmpty, blackCoverURI == uri {
        return blackCoverIsMostlyBlack
    }

    // A cover reads as "mostly black" when either its overall (blur-equivalent)
    // luminance is dark — this catches uniform dark covers whose anti-aliased
    // edges and JPEG noise hover just above the pixel threshold — or at least
    // a quarter of its pixels are black.
    guard let pixels = sampleCoverRGBA() else {
        writeDebugLog("[BlackUI] no artwork for uri=\(uri) -> forceBlack=false")
        return false
    }

    let ratio = coverBlackPixelRatio(pixels)
    let meanLuminance = coverMeanLuminance(pixels)
    let isMostlyBlack = meanLuminance < blackLuminanceThreshold
        || ratio >= blackPixelRatioThreshold
    if !uri.isEmpty {
        blackCoverURI = uri
        blackCoverIsMostlyBlack = isMostlyBlack
    }
    writeDebugLog("[BlackUI] cover meanLum=\(String(format: "%.2f", meanLuminance)) blackRatio=\(String(format: "%.2f", ratio)) for uri=\(uri) -> forceBlack=\(isMostlyBlack)")
    return isMostlyBlack
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
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
        if isNowPlayingGradientLayer(target), shouldForceBlackGradient() {
            orig.setColors([UIColor.black.cgColor, UIColor.black.cgColor])
            return
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
