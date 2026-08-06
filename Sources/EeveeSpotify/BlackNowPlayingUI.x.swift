import Orion
import UIKit
import QuartzCore
import MediaPlayer

struct BlackNowPlayingUIGroup: HookGroup {}

// The verdict and the gradient layers it applies to. The gradient layers are
// discovered through the CAGradientLayer.setColors: hook (both
// NowPlaying_ScrollImpl.NPVGradientView and NowPlaying_MixingTransitionImpl
// expose a CAGradientLayer with a NPVGradientView delegate). The verdict is
// resolved FRESH on a repeating poller from the actual album artwork pixels —
// the only signal that reliably says "this cover is mostly black" (Spotify's
// metadata extracted_color is a mood color that can be mid-tone on black
// covers). The poller — not a single callback — drives it, because Spotify
// swaps Now Playing implementations (scroll vs. canvas / mixing-transition)
// around track switches, and any one callback stops firing on some paths.
private let blackLuminanceThreshold = 0.2
private let blackPixelRatioThreshold = 0.25

// --- Artwork analysis cache, keyed by the live track URI ---
// MPNowPlayingInfoCenter artwork updates per track in this build (see the
// [CANVAS][NPIC] logs), so sampling it is fresh per switch. The cache is
// keyed by the live URI so a track switch always re-samples the new cover;
// within one track it short-circuits so the 0.5s poller never re-decodes.
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

private let gradientLayerLock = NSLock()
private let gradientLayers = NSHashTable<CAGradientLayer>.weakObjects()
private var originalColorsByLayer: [ObjectIdentifier: [CGColor]] = [:]
private var lastSeenOriginalColors: [CGColor]?

private var forceBlackVerdict = false
private var lastAppliedVerdict = false
private var lastLogDetail = ""

private func registerGradientLayer(_ layer: CAGradientLayer, originalColors: [CGColor]?) {
    gradientLayerLock.lock(); defer { gradientLayerLock.unlock() }
    gradientLayers.add(layer)
    // Never record a forced-paint: setting layer.colors to black re-enters the
    // setColors: hook with the black colors, and overwriting the stored
    // originals with black would make the revert path restore black forever.
    if !forceBlackVerdict, let colors = originalColors {
        originalColorsByLayer[ObjectIdentifier(layer)] = colors
        lastSeenOriginalColors = colors
    }
}

private func restoreAllGradientLayers() {
    gradientLayerLock.lock()
    let layers = gradientLayers.allObjects
    let originals = originalColorsByLayer
    gradientLayerLock.unlock()

    let restore = {
        for layer in layers {
            if let colors = originals[ObjectIdentifier(layer)] {
                layer.colors = colors
            }
        }
    }
    if Thread.isMainThread { restore() } else { DispatchQueue.main.async(execute: restore) }
    forceBlackVerdict = false
    lastAppliedVerdict = false
}

// Relative luminance of a UIColor (0 = pure black, 1 = pure white). Returns
// nil when the color isn't in a convertible (RGB) color space.
private func colorLuminance(_ color: UIColor) -> Double? {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
}

private func luminance(ofColors colors: [CGColor]) -> Double? {
    guard !colors.isEmpty else { return nil }
    var sum = 0.0
    for cgColor in colors {
        if let luminance = colorLuminance(UIColor(cgColor: cgColor)) {
            sum += luminance
        }
    }
    return sum / Double(colors.count)
}

// Relative luminance of a hex color string (#RRGGBB / #RGB / 0xRRGGBB).
// Returns nil for unparseable input.
private func hexLuminance(_ hex: String) -> Double? {
    var cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
        cleaned = String(cleaned.dropFirst(2))
    }
    guard !cleaned.isEmpty else { return nil }
    var int: UInt64 = 0
    guard Scanner(string: cleaned).scanHexInt64(&int) else { return nil }
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

// Identity of the currently playing track, from the live player state (never
// stale). Used to key the artwork cache so a switch always re-samples.
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

// Sample the current album cover into a small fixed-size RGBA buffer. Raw
// pixels are the only reliable "is this cover mostly black" signal; CoreImage
// blur failed silently on-device (see earlier iterations). Returns nil when no
// artwork is available (e.g. a local file without a cover).
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
// luminance below `blackLuminanceThreshold`).
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
// out highlights, text and JPEG noise. Returns 1 (light) when no artwork is
// available so a missing cover never forces black on its own.
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

// The live track's server-side extracted album color (mood color). Weak
// signal — a mostly-black cover can still yield a mid-tone extracted color —
// used only as a fallback when no artwork is available to sample.
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

// Resolve the force-black verdict FRESH from live sources, in order:
// 1) the actual album artwork pixels — the ground truth for "cover is mostly
//    black" (mean luminance dark, or >= 25% black pixels). Keyed by the live
//    track URI so a switch re-samples; within a track it uses the cache;
// 2) the live track's extracted mood color (weak);
// 3) the gradient layers' last original Spotify colors;
// 4) the header view model's live color.
// Returns nil when nothing is available — the caller then keeps the previous
// verdict so a brief no-artwork gap during a transition can't flicker the
// gradient back to colorful.
private func resolveForceBlackVerdict() -> (Bool, String, String)? {
    let uri = liveTrackURIString()

    if !uri.isEmpty, uri == blackCoverURI, blackCoverPixels != nil {
        return (blackCoverIsMostlyBlack, "artworkPixels", uri)
    }

    if let pixels = sampleCoverRGBA() {
        if blackCoverURI != uri {
            blackCoverURI = uri
            blackCoverPixels = nil
        }
        if blackCoverPixels == pixels {
            return (blackCoverIsMostlyBlack, "artworkPixels", uri)
        }
        let ratio = coverBlackPixelRatio(pixels)
        let meanLuminance = coverMeanLuminance(pixels)
        let isMostlyBlack = meanLuminance < blackLuminanceThreshold
            || ratio >= blackPixelRatioThreshold
        blackCoverPixels = pixels
        blackCoverIsMostlyBlack = isMostlyBlack
        return (isMostlyBlack, "artworkPixels", uri)
    }

    if let hex = liveTrackExtractedColorHex(), let luminance = hexLuminance(hex) {
        return (luminance < blackLuminanceThreshold, "extractedColor", hex)
    }
    if let colors = lastSeenOriginalColors, let luminance = luminance(ofColors: colors) {
        return (luminance < blackLuminanceThreshold, "gradientColors", String(format: "%.2f", luminance))
    }
    if let color = backgroundViewModel?.color(), let luminance = colorLuminance(color) {
        return (luminance < blackLuminanceThreshold, "backgroundViewModel", String(format: "%.2f", luminance))
    }
    return nil
}

// Re-resolves the verdict and applies it to every registered now-playing
// gradient layer. Layers that should be black get pure black; layers that
// shouldn't get the last original colors Spotify applied (so the gradient
// reverts to the album colors). Only touches layers when the verdict actually
// changed, so repeated poller ticks don't fight Spotify's own animations.
private func refreshGradientVerdict() {
    guard UserDefaults.blackNowPlayingUI else {
        if forceBlackVerdict {
            restoreAllGradientLayers()
        }
        return
    }

    guard let (force, source, detail) = resolveForceBlackVerdict() else {
        return // no source — keep the previous verdict, don't flicker
    }

    if detail != lastLogDetail {
        writeDebugLog("[BlackUI] resolve: \(source) \(detail) -> forceBlack=\(force)")
        lastLogDetail = detail
    }

    forceBlackVerdict = force
    guard forceBlackVerdict != lastAppliedVerdict else { return }

    // Commit the verdict BEFORE applying: setting layer.colors re-enters the
    // setColors: hook synchronously, and refreshGradientVerdict() runs again
    // inside that hook. With the new verdict already committed, the re-entrant
    // call short-circuits on the guard above instead of recursing forever.
    lastAppliedVerdict = forceBlackVerdict

    gradientLayerLock.lock()
    let layers = gradientLayers.allObjects
    let originals = originalColorsByLayer
    gradientLayerLock.unlock()

    let apply = {
        for layer in layers {
            if forceBlackVerdict {
                layer.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
            } else if let colors = originals[ObjectIdentifier(layer)] {
                layer.colors = colors
            }
        }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
}

// Intercepts every gradient color application in the app, but only tracks and
// overrides layers owned by the now-playing gradient views (ScrollImpl /
// MixingTransitionImpl.NPVGradientView). The verdict is re-resolved fresh on
// every paint (cheap, and the per-track cache short-circuits) so a paint that
// arrives right after a switch already carries the new track's verdict.
class NowPlayingGradientLayerHook: ClassHook<CAGradientLayer> {
    typealias Group = BlackNowPlayingUIGroup
    static let targetName = "CAGradientLayer"

    func setColors(_ colors: [CGColor]?) {
        if isNowPlayingGradientLayer(target) {
            registerGradientLayer(target, originalColors: colors)
            refreshGradientVerdict()
            if forceBlackVerdict {
                orig.setColors([UIColor.black.cgColor, UIColor.black.cgColor])
                return
            }
        }
        orig.setColors(colors)
    }
}

// The header's per-track color callback (card-render time). Not the driver —
// the poller is — but a nudge so a switch flips the gradient immediately
// instead of on the next poll tick. Hooking NPVBackgroundViewController only
// helps on the scroll path; the poller covers every other path.
class NPVBackgroundViewControllerHook: ClassHook<NSObject> {
    typealias Group = BlackNowPlayingUIGroup
    static let targetName = "NowPlaying_ScrollImpl.NPVBackgroundViewController"

    func backgroundViewModel(_ viewModel: NSObject, didChangeColor color: UIColor, playerState: NSObject?) {
        orig.backgroundViewModel(viewModel, didChangeColor: color, playerState: playerState)
        refreshGradientVerdict()
    }
}

// Repeating poller: re-resolves the verdict every 0.5s on the main runloop in
// .common mode (so it fires during scroll tracking and canvas playback, where
// the .default-mode timer would pause). This is the piece that makes the
// feature self-healing: no matter which Now Playing implementation Spotify
// swaps to, within one tick the gradient reflects the CURRENT track's artwork.
private var verdictPoller: Timer?

private func startVerdictPoller() {
    guard verdictPoller == nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
        refreshGradientVerdict()
    }
    RunLoop.main.add(timer, forMode: .common)
    verdictPoller = timer
}

func activateBlackNowPlayingUI() {
    guard NSClassFromString("CAGradientLayer") != nil else {
        writeDebugLog("[BlackUI] skipped: CAGradientLayer unavailable")
        return
    }
    BlackNowPlayingUIGroup().activate()
    startVerdictPoller()
    writeDebugLog("[BlackUI] activated")
}
