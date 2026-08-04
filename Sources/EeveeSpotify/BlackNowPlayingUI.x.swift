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

/// Fraction of the current album cover's pixels that read as black
/// (relative luminance below `blackLuminanceThreshold`).
/// Returns 0 when no artwork is available (e.g. local file without a cover).
private func albumCoverBlackRatio() -> Double {
    guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
          let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
        return 0
    }

    // Ask for a modest size — enough for a stable dark-ratio estimate.
    let cover = artwork.image(at: CGSize(width: 64, height: 64))
    guard cover != nil else { return 0 }

    // Downscale to 32x32 (1024 pixels) for a cheap, representative sample.
    let sampleSize = CGSize(width: 32, height: 32)
    UIGraphicsBeginImageContextWithOptions(sampleSize, false, 1)
    cover?.draw(in: CGRect(origin: .zero, size: sampleSize))
    let sampled = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    guard let cgImage = sampled?.cgImage,
          let data = cgImage.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else {
        return 0
    }

    let bytesPerPixel = cgImage.bitsPerPixel / 8
    guard bytesPerPixel >= 3 else { return 0 }

    let total = cgImage.width * cgImage.height
    guard total > 0 else { return 0 }

    var dark = 0
    for i in 0..<total {
        let offset = i * bytesPerPixel
        let r = Double(bytes[offset]) / 255.0
        let g = Double(bytes[offset + 1]) / 255.0
        let b = Double(bytes[offset + 2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance < 0.2 {
            dark += 1
        }
    }
    return Double(dark) / Double(total)
}

private func shouldForceBlackGradient() -> Bool {
    guard UserDefaults.blackNowPlayingUI else { return false }

    let uri = capturedTrackURI ?? ""
    if blackCoverURI == uri {
        return blackCoverIsMostlyBlack
    }

    let ratio = albumCoverBlackRatio()
    blackCoverURI = uri
    blackCoverIsMostlyBlack = ratio >= 0.5
    writeDebugLog("[BlackUI] cover blackRatio=\(String(format: "%.2f", ratio)) for uri=\(uri) -> forceBlack=\(blackCoverIsMostlyBlack)")
    return blackCoverIsMostlyBlack
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
