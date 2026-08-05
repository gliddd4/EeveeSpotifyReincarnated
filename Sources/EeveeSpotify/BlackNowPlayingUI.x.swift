import Orion
import UIKit
import QuartzCore
import MediaPlayer
import CoreImage

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

// Shared CIContext so the Gaussian-blur + area-average work reuses the GPU
// pipeline instead of paying per-call context creation.
private let blackCoverCIContext = CIContext(options: [.workingColorSpace: NSNull()])

/// Relative luminance (0...1) of a color; judges how "black" it reads.
private func relativeLuminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 1 }
    return 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
}

/// The album cover's dominant ("primary") color: the artwork is Gaussian-
/// blurred to smooth out highlights, text and JPEG noise, then reduced to a
/// 1x1 area average. Returns nil when no artwork is available (e.g. a local
/// file without a cover).
private func coverPrimaryColor() -> UIColor? {
    guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
          let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
          let cover = artwork.image(at: CGSize(width: 128, height: 128)),
          let cgImage = cover.cgImage else {
        return nil
    }

    let input = CIImage(cgImage: cgImage)
    let blurred = input
        .clampedToExtent()
        .applyingGaussianBlur(sigma: 8)
        .cropped(to: input.extent)
    let averaged = blurred.applyingFilter(
        "CIAreaAverage",
        parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)]
    )

    var pixel = [UInt8](repeating: 0, count: 4)
    blackCoverCIContext.render(
        averaged,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: nil
    )
    return UIColor(
        red: CGFloat(pixel[0]) / 255.0,
        green: CGFloat(pixel[1]) / 255.0,
        blue: CGFloat(pixel[2]) / 255.0,
        alpha: 1.0
    )
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
        if luminance < blackLuminanceThreshold {
            dark += 1
        }
    }
    return Double(dark) / Double(total)
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
    if blackCoverURI == uri {
        return blackCoverIsMostlyBlack
    }

    // A cover reads as "mostly black" when either the Gaussian-blurred
    // primary color is dark (this catches uniform dark covers whose
    // anti-aliased edges and JPEG noise hover just above the pixel
    // threshold) or at least a quarter of its pixels are black.
    let ratio = albumCoverBlackRatio()
    let primaryLuminance = coverPrimaryColor().map(relativeLuminance)
    let isMostlyBlack = (primaryLuminance.map { $0 < blackLuminanceThreshold } ?? false)
        || ratio >= 0.25
    blackCoverURI = uri
    blackCoverIsMostlyBlack = isMostlyBlack
    writeDebugLog("[BlackUI] cover primaryLum=\(primaryLuminance.map { String(format: "%.2f", $0) } ?? "nil") blackRatio=\(String(format: "%.2f", ratio)) for uri=\(uri) -> forceBlack=\(isMostlyBlack)")
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
