import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0
private weak var appliedPill: UIView?

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

// Locates the floating pill (NowPlaying_BarImpl.NowPlayingBarView).
//
// Two-tier scoring: a view whose class name contains "NowPlayingBarView" always
// beats a frame-only match, so a name-matched pill can't lose to a larger
// wrapper container that happens to satisfy the frame signature. Among equal
// scores the deepest match wins (the pill, not its parent). The frame arm
// (56pt tall, ~8pt inset) is the fallback when the class name changes between
// Spotify builds.
private func findNowPlayingBarPill(in root: UIView) -> UIView? {
    var best: UIView?
    var bestScore = 0
    var bestDepth = -1
    let screenWidth = UIScreen.main.bounds.width

    func walk(_ view: UIView, depth: Int) {
        let name = NSStringFromClass(type(of: view))
        let inset = view.frame.minX
        let isInsetPill = view.bounds.height >= 48 && view.bounds.height <= 64
            && inset >= 4 && inset <= 16
            && view.frame.width >= screenWidth - 24
        let score = (name.contains("NowPlayingBarView") ? 2 : 0) + (isInsetPill ? 1 : 0)

        if score > 0, score > bestScore || (score == bestScore && depth > bestDepth) {
            best = view
            bestScore = score
            bestDepth = depth
        }
        for sub in view.subviews {
            walk(sub, depth: depth + 1)
        }
    }

    walk(root, depth: 0)
    if let best {
        writeDebugLog("[LiquidGlassNPB] Pill candidate: \(NSStringFromClass(type(of: best)))")
    }
    return best
}

// The cleanup half is idempotent and re-runs on every layout pass, so content
// Spotify adds after our first pass can never cover the glass. Only the glass
// insertion is one-shot (guarded by the associated object).
@available(iOS 26.0, *)
private func applyLiquidGlass(toPill pill: UIView) {
    let applied = objc_getAssociatedObject(pill, &liquidGlassAppliedKey) != nil

    // Spotify draws its border/shadow/glow on a view expanded ~4pt beyond the
    // pill (382x64 vs 374x56). Hide only views expanded on ALL sides so we
    // never touch legitimately overflowing content (artwork bleed, knobs).
    for sub in pill.subviews
        where sub.frame.minX <= -2 && sub.frame.minY <= -2
            && sub.frame.maxX >= pill.bounds.maxX + 2
            && sub.frame.maxY >= pill.bounds.maxY + 2 {
        sub.isHidden = true
    }

    // Neutralize the artwork-tinted fill (plain UIView backgrounds + any
    // gradient layer on the pill) so the glass can show through.
    func clearFill(_ view: UIView) {
        if NSStringFromClass(type(of: view)) == "UIView" {
            view.backgroundColor = .clear
            view.layer.backgroundColor = nil
        }
        for sub in view.subviews {
            clearFill(sub)
        }
    }
    clearFill(pill)
    pill.backgroundColor = .clear
    pill.layer.backgroundColor = nil
    if let gradient = pill.layer as? CAGradientLayer {
        gradient.colors = nil
    }

    guard !applied else { return }

    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = true
    let glass = UIVisualEffectView(effect: glassEffect)
    glass.cornerConfiguration = .capsule()
    glass.isUserInteractionEnabled = false
    glass.isAccessibilityElement = false
    glass.translatesAutoresizingMaskIntoConstraints = false

    pill.insertSubview(glass, at: 0)
    NSLayoutConstraint.activate([
        glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
        glass.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
        glass.topAnchor.constraint(equalTo: pill.topAnchor),
        glass.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
    ])

    objc_setAssociatedObject(pill, &liquidGlassAppliedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    appliedPill = pill
}

class NowPlayingBarViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LiquidGlassNowPlayingBarGroup
    static var targetName = "NowPlaying_BarImpl.NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()

        if #available(iOS 26.0, *),
           let pill = appliedPill ?? findNowPlayingBarPill(in: target.view) {
            applyLiquidGlass(toPill: pill)
        }
    }
}
