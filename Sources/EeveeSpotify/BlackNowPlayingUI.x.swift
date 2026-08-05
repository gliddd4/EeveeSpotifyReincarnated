import Orion
import UIKit
import QuartzCore

struct BlackNowPlayingUIGroup: HookGroup {}

// The verdict and the gradient layers it applies to. The gradient layers are
// discovered through the CAGradientLayer.setColors: hook (both
// NowPlaying_ScrollImpl.NPVGradientView and NowPlaying_MixingTransitionImpl
// expose a CAGradientLayer with a NPVGradientView delegate). The verdict is
// resolved FRESH on a repeating timer from the live track's server-extracted
// album color (the same stable per-track source the lyrics pipeline uses),
// falling back to the gradient's own original Spotify colors, then the header
// view model's live color. A poller — not a single callback — drives it,
// because Spotify swaps Now Playing implementations (scroll vs. canvas /
// mixing-transition) around track switches, and any one callback (e.g. the
// header's backgroundViewModel:didChangeColor:) stops firing on some paths,
// which is exactly how the verdict used to latch forever.
private let blackLuminanceThreshold = 0.2

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
    if let colors = originalColors {
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

// The live track's server-side extracted album color, mirroring how the lyrics
// pipeline resolves it (resolvedTrackExtractedColor). Stable per track — it
// can never be a transient canvas/transition frame color the way the header's
// live color can.
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
// 1) the live track's server-extracted album color (stable, works on 9.1.x
//    for cloud and local tracks, immune to canvas/transition transients);
// 2) the gradient layers' last original Spotify colors — per-track by
//    construction, impl-independent (covers the canvas/mixing paths);
// 3) the header view model's live color (last resort).
private func resolveForceBlackVerdict() -> (Bool, String, String) {
    if let hex = liveTrackExtractedColorHex(), let luminance = hexLuminance(hex) {
        return (luminance < blackLuminanceThreshold, "extractedColor", hex)
    }
    if let colors = lastSeenOriginalColors, let luminance = luminance(ofColors: colors) {
        return (luminance < blackLuminanceThreshold, "gradientColors", String(format: "%.2f", luminance))
    }
    if let color = backgroundViewModel?.color(), let luminance = colorLuminance(color) {
        return (luminance < blackLuminanceThreshold, "backgroundViewModel", String(format: "%.2f", luminance))
    }
    return (false, "none", "no source")
}

// Re-resolves the verdict and applies it to every registered now-playing
// gradient layer. Layers that should be black get pure black; layers that
// shouldn't get the last original colors Spotify applied (so the gradient
// reverts to the album colors). Only touches layers when the verdict actually
// changed, so repeated triggers don't fight Spotify's own animations.
private func refreshGradientVerdict() {
    guard UserDefaults.blackNowPlayingUI else {
        if forceBlackVerdict {
            restoreAllGradientLayers()
        }
        return
    }

    let (force, source, detail) = resolveForceBlackVerdict()
    if detail != lastLogDetail {
        writeDebugLog("[BlackUI] resolve: \(source) \(detail) -> forceBlack=\(force)")
        lastLogDetail = detail
    }

    forceBlackVerdict = force
    guard forceBlackVerdict != lastAppliedVerdict else { return }

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
    lastAppliedVerdict = forceBlackVerdict
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
}

// Intercepts every gradient color application in the app, but only tracks and
// overrides layers owned by the now-playing gradient views (ScrollImpl /
// MixingTransitionImpl.NPVGradientView). The verdict is re-resolved fresh on
// every paint (cheap) so a paint that arrives right after a switch already
// carries the new track's verdict.
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
// swaps to, within one tick the gradient reflects the CURRENT track's color.
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
