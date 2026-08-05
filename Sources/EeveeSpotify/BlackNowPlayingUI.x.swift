import Orion
import UIKit
import QuartzCore

struct BlackNowPlayingUIGroup: HookGroup {}

// The verdict and the gradient layers it applies to. The gradient layers are
// discovered through the CAGradientLayer.setColors: hook (both
// NowPlaying_ScrollImpl.NPVGradientView and NowPlaying_MixingTransitionImpl
// expose a CAGradientLayer with a NPVGradientView delegate); the verdict is
// driven by NPVBackgroundViewController.backgroundViewModel:didChangeColor:
// playerState:, which the header fires once per track switch with the new
// album color — the same per-track signal the header/lyrics features use
// instead of the laggy statefulPlayer.currentTrack() or the (first-track
// pinned) MPNowPlayingInfoCenter artwork.
private let blackLuminanceThreshold = 0.2

private let gradientLayerLock = NSLock()
private let gradientLayers = NSHashTable<CAGradientLayer>.weakObjects()
private var originalColorsByLayer: [ObjectIdentifier: [CGColor]] = [:]

private var forceBlackVerdict = false
private var lastAppliedVerdict = false

private func registerGradientLayer(_ layer: CAGradientLayer, originalColors: [CGColor]?) {
    gradientLayerLock.lock(); defer { gradientLayerLock.unlock() }
    gradientLayers.add(layer)
    if let colors = originalColors {
        originalColorsByLayer[ObjectIdentifier(layer)] = colors
    }
}

// Relative luminance of a UIColor (0 = pure black, 1 = pure white). Returns
// nil when the color isn't in a convertible (RGB) color space.
private func colorLuminance(_ color: UIColor) -> Double? {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
}

// Applies the current verdict to every registered now-playing gradient layer.
// Layers that should be black get pure black; layers that shouldn't get the
// last original colors Spotify applied (so the gradient reverts to the album
// colors). Only touches layers when the verdict actually changed, so repeated
// triggers (setColors: fires per layout/animation tick) don't fight Spotify's
// own animations.
private func applyVerdict() {
    guard forceBlackVerdict != lastAppliedVerdict else { return }
    lastAppliedVerdict = forceBlackVerdict

    gradientLayerLock.lock()
    let layers = gradientLayers.allObjects
    gradientLayerLock.unlock()

    let apply = {
        for layer in layers {
            if forceBlackVerdict {
                layer.colors = [UIColor.black.cgColor, UIColor.black.cgColor]
            } else if let originals = originalColorsByLayer[ObjectIdentifier(layer)] {
                layer.colors = originals
            }
        }
    }
    if Thread.isMainThread {
        apply()
    } else {
        DispatchQueue.main.async(execute: apply)
    }
}

// Updates the verdict from a freshly resolved album color (the header's
// didChangeColor argument, or the header view model's live color), then
// applies it to the gradient layers.
private func evaluateVerdict(from color: UIColor, source: String) {
    guard UserDefaults.blackNowPlayingUI,
          let luminance = colorLuminance(color) else { return }
    forceBlackVerdict = luminance < blackLuminanceThreshold
    writeDebugLog("[BlackUI] \(source) lum=\(String(format: "%.2f", luminance)) -> forceBlack=\(forceBlackVerdict)")
    applyVerdict()
}

// --- Bounded re-check ---
// Safety net for ordering races: didChangeColor and setColors: can arrive in
// either order around a track switch, and the header's color may settle after
// the gradient is painted. Each run re-reads the header's live color (the
// same value the didChangeColor callback carries) and re-applies if the
// verdict flipped. Never reschedules over a pending work item — setColors:
// fires on every layout/animation tick, and cancelling here would starve the
// re-check forever.
private let gradientRecheckInterval: TimeInterval = 1.5
private let gradientRecheckMaxAttempts = 6
private var gradientRecheckAttempt = 0
private var gradientRecheckWorkItem: DispatchWorkItem?

private func scheduleGradientRecheck() {
    guard gradientRecheckWorkItem == nil else { return }
    let item = DispatchWorkItem { runGradientRecheck() }
    gradientRecheckWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + gradientRecheckInterval, execute: item)
}

private func runGradientRecheck() {
    gradientRecheckWorkItem = nil
    guard UserDefaults.blackNowPlayingUI else { return }

    // The header view model's color() is the live per-track album color —
    // same source as the didChangeColor argument, refreshed at render time.
    if let color = backgroundViewModel?.color() {
        evaluateVerdict(from: color, source: "recheck:backgroundViewModel")
        return
    }

    if gradientRecheckAttempt < gradientRecheckMaxAttempts {
        gradientRecheckAttempt += 1
        scheduleGradientRecheck()
    }
}

private func isNowPlayingGradientLayer(_ layer: CAGradientLayer) -> Bool {
    guard let view = layer.delegate as? UIView else { return false }
    return NSStringFromClass(type(of: view)).contains("NPVGradientView")
}

// Intercepts every gradient color application in the app, but only tracks and
// overrides layers owned by the now-playing gradient views (ScrollImpl /
// MixingTransitionImpl.NPVGradientView). The verdict is driven by the header's
// per-track color callback, so a track switch to a black cover applies black
// and a switch to a light cover restores Spotify's own colors.
class NowPlayingGradientLayerHook: ClassHook<CAGradientLayer> {
    typealias Group = BlackNowPlayingUIGroup
    static let targetName = "CAGradientLayer"

    func setColors(_ colors: [CGColor]?) {
        if isNowPlayingGradientLayer(target) {
            registerGradientLayer(target, originalColors: colors)
            gradientRecheckAttempt = 0
            scheduleGradientRecheck()
            if forceBlackVerdict {
                orig.setColors([UIColor.black.cgColor, UIColor.black.cgColor])
                return
            }
        }
        orig.setColors(colors)
    }
}

// The header's per-track color callback — fires once per track switch with the
// new album color (card-render time, never lagged like currentTrack()). This is
// the track-switch detection the header functionality uses; the gradient verdict
// piggybacks on it.
class NPVBackgroundViewControllerHook: ClassHook<NSObject> {
    typealias Group = BlackNowPlayingUIGroup
    static let targetName = "NowPlaying_ScrollImpl.NPVBackgroundViewController"

    func backgroundViewModel(_ viewModel: NSObject, didChangeColor color: UIColor, playerState: NSObject?) {
        orig.backgroundViewModel(viewModel, didChangeColor: color, playerState: playerState)
        evaluateVerdict(from: color, source: "didChangeColor")
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
