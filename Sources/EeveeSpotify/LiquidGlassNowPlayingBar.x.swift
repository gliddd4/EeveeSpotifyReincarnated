import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0
private var liquidGlassDiagnosticsKey = 0

func activateLiquidGlassNowPlayingBar() {
    guard UserDefaults.liquidGlassNowPlayingBar else {
        writeDebugLog("[LiquidGlassNPB] Disabled in settings")
        return
    }

    let major = Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "") ?? 0
    guard major >= 26 else {
        writeDebugLog("[LiquidGlassNPB] Requires iOS 26 (running \(UIDevice.current.systemVersion))")
        return
    }

    guard NSClassFromString("UIGlassEffect") != nil,
          NSClassFromString("NowPlaying_BarImpl.NowPlayingBarViewController") != nil else {
        writeDebugLog("[LiquidGlassNPB] UIGlassEffect or NowPlayingBarViewController unavailable")
        return
    }

    LiquidGlassNowPlayingBarGroup().activate()
    writeDebugLog("[LiquidGlassNPB] Activated")
}

// Applies the glass material to the bar's root view (the VC's view). The root
// is the one view we know is the bar, so no pill-finding heuristics are needed.
//
// The cleanup half is idempotent and re-runs on every layout pass, so content
// Spotify adds after our first pass can never cover the glass. Only the glass
// insertion is one-shot (guarded by the associated object).
@available(iOS 26.0, *)
private func applyLiquidGlass(toBar bar: UIView) {
    let barBounds = bar.bounds

    if objc_getAssociatedObject(bar, &liquidGlassDiagnosticsKey) == nil {
        writeDebugLog("[LiquidGlassNPB] Bar: \(NSStringFromClass(type(of: bar))) frame=\(bar.frame) cornerRadius=\(bar.layer.cornerRadius) masksToBounds=\(bar.layer.masksToBounds) clips=\(bar.clipsToBounds) bg=\(String(describing: bar.backgroundColor))")
        for sub in bar.subviews {
            writeDebugLog("[LiquidGlassNPB]   sub: \(NSStringFromClass(type(of: sub))) frame=\(sub.frame) cornerRadius=\(sub.layer.cornerRadius) bg=\(String(describing: sub.backgroundColor)) hidden=\(sub.isHidden)")
            for child in sub.subviews {
                writeDebugLog("[LiquidGlassNPB]     child: \(NSStringFromClass(type(of: child))) frame=\(child.frame) bg=\(String(describing: child.backgroundColor))")
            }
        }
        objc_setAssociatedObject(bar, &liquidGlassDiagnosticsKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // Spotify draws its border/shadow/glow on a view expanded ~4pt beyond the
    // bar (382x64 vs 374x56). Hide only views expanded on ALL sides so we
    // never touch legitimately overflowing content (artwork bleed, knobs).
    for sub in bar.subviews
        where sub.frame.minX <= -2 && sub.frame.minY <= -2
            && sub.frame.maxX >= barBounds.maxX + 2
            && sub.frame.maxY >= barBounds.maxY + 2 {
        sub.isHidden = true
        writeDebugLog("[LiquidGlassNPB] Hidden expanded border view: \(NSStringFromClass(type(of: sub))) frame=\(sub.frame)")
    }

    // Neutralize every opaque fill: the bar's own background, all plain
    // UIView containers, and any view (any class) that covers the full bar —
    // the artwork-tinted background is a subclass (NowPlayingBarTopStack), so
    // clearing only plain UIViews is not enough. Content views (artwork,
    // labels, buttons) are smaller than 85% of the bar and are left alone.
    func clearFill(_ view: UIView) {
        let covers = view.bounds.width >= barBounds.width * 0.85
            && view.bounds.height >= barBounds.height * 0.85
        let isPlain = NSStringFromClass(type(of: view)) == "UIView"
        if covers || isPlain {
            view.backgroundColor = .clear
            view.layer.backgroundColor = nil
            if let gradient = view.layer as? CAGradientLayer {
                gradient.colors = nil
            }
        }
        for child in view.subviews {
            clearFill(child)
        }
    }
    clearFill(bar)
    bar.backgroundColor = .clear
    bar.layer.backgroundColor = nil
    if let gradient = bar.layer as? CAGradientLayer {
        gradient.colors = nil
    }

    guard objc_getAssociatedObject(bar, &liquidGlassAppliedKey) == nil else { return }

    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = true
    let glass = UIVisualEffectView(effect: glassEffect)
    glass.cornerConfiguration = .capsule()
    glass.isUserInteractionEnabled = false
    glass.isAccessibilityElement = false
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.layer.borderWidth = 0.5
    glass.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor

    bar.insertSubview(glass, at: 0)
    glass.frame = barBounds
    NSLayoutConstraint.activate([
        glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
        glass.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        glass.topAnchor.constraint(equalTo: bar.topAnchor),
        glass.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
    ])

    objc_setAssociatedObject(bar, &liquidGlassAppliedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    writeDebugLog("[LiquidGlassNPB] Glass applied to bar frame=\(bar.frame)")
}

class NowPlayingBarViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LiquidGlassNowPlayingBarGroup
    static var targetName = "NowPlaying_BarImpl.NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()

        if #available(iOS 26.0, *) {
            applyLiquidGlass(toBar: target.view)
        }
    }
}
