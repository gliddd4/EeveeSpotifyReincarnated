import Orion
import UIKit
import QuartzCore
import MediaPlayer

struct BlackNowPlayingUIGroup: HookGroup {}

// Black-cover analysis cache, keyed by the sampled artwork itself (not the
// track URI) so a repeated setColors: (layout pass, animation tick) reuses the
// last result instead of re-scanning the cover every time. Keying by URI went
// stale: capturedTrackURI only fires on viewWillAppear, so in-session track
// changes kept the old key and returned the first album's verdict until the
// app was relaunched.
private let blackCoverQueue = DispatchQueue(label: "com.eeveespotify.blackcover")
private var _blackCoverPixels: [UInt8]?
private var _blackCoverIsMostlyBlack = false

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

    guard let pixels = sampleCoverRGBA() else {
        writeDebugLog("[BlackUI] no artwork -> forceBlack=false")
        return false
    }

    // Same artwork as the last verdict (animation ticks, repeated layout
    // passes) — reuse the result instead of re-scanning. On track change the
    // artwork differs, so this cache miss recomputes for the new cover; the
    // previous URI-keyed cache could not do that because capturedTrackURI is
    // pinned to the first track's viewWillAppear and never updates.
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
    let uri = capturedTrackURI
        ?? statefulPlayer?.currentTrack().flatMap { ($0.URI() as? NSURL)?.absoluteString }
        ?? ""
    writeDebugLog("[BlackUI] cover meanLum=\(String(format: "%.2f", meanLuminance)) blackRatio=\(String(format: "%.2f", ratio)) uri=\(uri) -> forceBlack=\(isMostlyBlack)")
    return isMostlyBlack
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
}

// --- Delayed re-check state ---
// MPNowPlayingInfoCenter artwork settles shortly after the gradient's
// setColors: fires on track change, so the first verdict can be computed
// from the previous track's cover and the gradient stays stale until the
// app relaunches (relaunch resets the cache globals). When setColors fires
// we schedule a short re-check loop: each tick re-samples the artwork and,
// once it has settled on the new cover, flips the gradient to match. The
// loop is bounded so a track with no artwork (or a switch to nothing) can't
// keep it running forever; any later setColors: reschedules a fresh loop.
private let gradientRecheckInterval: TimeInterval = 1.5
private let gradientRecheckMaxAttempts = 6

private var gradientRecheckHook: NowPlayingGradientLayerHook?
private var gradientRecheckOriginalColors: [CGColor]?
private var gradientRecheckAppliedBlack = false
private var gradientRecheckAttempt = 0
private var gradientRecheckWorkItem: DispatchWorkItem?

private func scheduleGradientRecheck() {
    gradientRecheckWorkItem?.cancel()
    let item = DispatchWorkItem { runGradientRecheck() }
    gradientRecheckWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + gradientRecheckInterval, execute: item)
}

private func runGradientRecheck() {
    gradientRecheckWorkItem = nil
    guard let hook = gradientRecheckHook else { return }

    let forceBlack = shouldForceBlackGradient()
    if forceBlack != gradientRecheckAppliedBlack {
        // Verdict flipped — the artwork has settled on a new cover. Apply it
        // and stop watching; the next setColors: starts a fresh loop.
        gradientRecheckAppliedBlack = forceBlack
        let colors = forceBlack
            ? [UIColor.black.cgColor, UIColor.black.cgColor]
            : gradientRecheckOriginalColors
        hook.orig.setColors(colors)
        writeDebugLog("[BlackUI] recheck flipped gradient -> forceBlack=\(forceBlack)")
    } else if gradientRecheckAttempt < gradientRecheckMaxAttempts {
        // Artwork may still be settling (or still missing) — try again.
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
