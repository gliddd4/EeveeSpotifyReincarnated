import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0
private var liquidGlassBackdropKey = 0
private var liquidGlassStateKey = 0
private var liquidGlassPassKey = 0
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

// The bar's VC is a full-screen container; the mini player pill is one of its
// subviews — a full-width ~56pt capsule pinned near the bottom. The shadow
// view (expanded 4pt beyond every edge) and the full-width containers it sits
// inside are structurally excluded by scoring.
private func findNowPlayingBarPill(in root: UIView) -> UIView? {
    let screen = UIScreen.main.bounds
    var best: UIView?
    var bestScore = -1
    var bestDepth = -1
    var candidates: [(String, String, String, Int)] = []

    func walk(_ view: UIView, depth: Int) {
        for sub in view.subviews {
            walk(sub, depth: depth + 1)
        }
        let frame = view.frame
        // The pill is nested (frame is in its superview's coordinates), so the
        // bottom-of-screen check must use window coordinates, not view.frame.
        let windowFrame = view.convert(view.bounds, to: nil)
        // Shape is a hard gate: the pill is the only full-width ~56pt capsule
        // pinned to the bottom in window coordinates. Views that fail it — the
        // LIVE badge, 44pt buttons, containers not yet positioned — can never
        // win, even if they have a corner radius or an opaque fill.
        let isPillShape = frame.height >= 48 && frame.height <= 64
            && frame.width >= screen.width - 24 && frame.width <= screen.width + 2
            && windowFrame.maxY >= screen.height * 0.75 && windowFrame.maxY <= screen.height + 8
        guard isPillShape else { return }
        // An opaque background (album-art fill) separates the pill from the
        // transparent outline/glow view that surrounds it. The tint can be
        // applied to either property, so check both.
        let bg = view.backgroundColor?.cgColor ?? view.layer.backgroundColor
        let hasFill = (bg?.alpha ?? 0) > 0
        let score = (hasFill ? 2 : 0) + (view.layer.cornerRadius > 0 ? 1 : 0)

        candidates.append((NSStringFromClass(type(of: view)), "\(frame)", "\(windowFrame)", score))
        if score > bestScore || (score == bestScore && depth > bestDepth) {
            best = view
            bestScore = score
            bestDepth = depth
        }
    }

    walk(root, depth: 0)
    for (name, frame, windowFrame, score) in candidates {
        writeDebugLog("[LiquidGlassNPB] Candidate: \(name) frame=\(frame) window=\(windowFrame) score=\(score)")
    }
    if let best {
        writeDebugLog("[LiquidGlassNPB] Pill: \(NSStringFromClass(type(of: best))) frame=\(best.frame) windowFrame=\(best.convert(best.bounds, to: nil)) cornerRadius=\(best.layer.cornerRadius) bg=\(String(describing: best.backgroundColor))")
    }
    return best
}

// The cleanup half is idempotent and re-runs on every layout pass, so content
// Spotify adds after our first pass can never cover the glass. Only the glass
// insertion is one-shot (guarded by the associated object).
@available(iOS 26.0, *)
private func applyLiquidGlass(toPill pill: UIView) {
    let pillBounds = pill.bounds

    // Spotify draws its border/shadow/glow on a view expanded ~4pt beyond the
    // pill (398x64 vs 390x56). Hide only views expanded on ALL sides so we
    // never touch legitimately overflowing content (artwork bleed, knobs).
    for sub in pill.subviews
        where sub.frame.minX <= -2 && sub.frame.minY <= -2
            && sub.frame.maxX >= pillBounds.maxX + 2
            && sub.frame.maxY >= pillBounds.maxY + 2 {
        sub.isHidden = true
        writeDebugLog("[LiquidGlassNPB] Hidden border view: \(NSStringFromClass(type(of: sub))) frame=\(sub.frame)")
    }

    // The glass refracts whatever the player screen draws behind the pill, so
    // the pill's own gray tint must be stripped or it sits between the glass
    // and the screen. Strip opaque fills from the pill and any full-coverage
    // plain-UIView subview, every pass — Spotify may re-apply the tint. Content
    // views (artwork, labels, buttons) are smaller than 85% of the pill and are
    // left alone.
    func clearFill(_ view: UIView) {
        let covers = view.bounds.width >= pillBounds.width * 0.85
            && view.bounds.height >= pillBounds.height * 0.85
        let isPlain = NSStringFromClass(type(of: view)) == "UIView"
        if covers || isPlain {
            view.backgroundColor = .clear
            view.layer.backgroundColor = nil
            view.isOpaque = false
            if let gradient = view.layer as? CAGradientLayer {
                gradient.colors = nil
            }
        }
        for child in view.subviews {
            clearFill(child)
        }
    }
    clearFill(pill)
    pill.backgroundColor = .clear
    pill.layer.backgroundColor = nil
    pill.isOpaque = false

    // Timeline of the pill's appearance for debugging: the first passes are
    // always logged so the next export shows whether layout passes keep
    // firing; afterwards only changes are logged.
    let pass = (objc_getAssociatedObject(pill, &liquidGlassPassKey) as? Int ?? 0) + 1
    objc_setAssociatedObject(pill, &liquidGlassPassKey, pass, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    let content = "subviews=\(pill.subviews.count) bg=\(String(describing: pill.backgroundColor))"
    let last = objc_getAssociatedObject(pill, &liquidGlassStateKey) as? String
    if pass <= 10 || content != last {
        writeDebugLog("[LiquidGlassNPB] Pill state (pass \(pass)): \(content)")
    }
    objc_setAssociatedObject(pill, &liquidGlassStateKey, content, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    guard objc_getAssociatedObject(pill, &liquidGlassAppliedKey) == nil else { return }

    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = true
    glassEffect.tintColor = UIColor.white.withAlphaComponent(0.12)
    let glass = UIVisualEffectView(effect: glassEffect)
    glass.isUserInteractionEnabled = false
    glass.isAccessibilityElement = false
    glass.translatesAutoresizingMaskIntoConstraints = false
    // UIVisualEffectView defaults to systemBackgroundColor on iOS 26, which is
    // opaque black in dark mode and hides the glass entirely.
    glass.backgroundColor = .clear
    glass.isOpaque = false
    glass.layer.borderWidth = 0.5
    glass.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor

    // Match the pill's own nearly-rectangular radius; a full capsule would
    // crop the album art.
    let radius = max(pill.layer.cornerRadius, 1)
    let corner = UICornerRadius.fixed(radius)
    pill.cornerConfiguration = .corners(radius: corner)
    glass.cornerConfiguration = .corners(radius: corner)

    writeDebugLog("[LiquidGlassNPB] Glass created effect=\(String(describing: glass.effect)) bg=\(String(describing: glass.backgroundColor)) opaque=\(glass.isOpaque)")

    pill.insertSubview(glass, at: 0)
    glass.frame = pillBounds
    NSLayoutConstraint.activate([
        glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
        glass.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
        glass.topAnchor.constraint(equalTo: pill.topAnchor),
        glass.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
    ])

    objc_setAssociatedObject(pill, &liquidGlassAppliedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    appliedPill = pill
    writeDebugLog("[LiquidGlassNPB] Glass applied frame=\(pill.frame) inWindow=\(pill.window != nil)")

    // Spotify re-applies the album-art tint asynchronously after layout settles
    // (no further layout passes fire), so re-strip it shortly after insertion.
    for delay in [0.05, 0.2, 0.5] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak pill] in
            guard let pill, pill.window != nil else { return }
            pill.backgroundColor = .clear
            pill.layer.backgroundColor = nil
            clearFill(pill)
        }
    }
}

class NowPlayingBarViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LiquidGlassNowPlayingBarGroup
    static var targetName = "NowPlaying_BarImpl.NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()

        if #available(iOS 26.0, *) {
            // The bar VC runs layout passes before it is attached to the window
            // (everything at origin, frames garbage, no pill in the tree yet).
            // Wait until it is on screen or the finder picks up junk.
            guard target.view.window != nil else { return }

            let pill: UIView?
            if let cached = appliedPill, cached.isDescendant(of: target.view) {
                pill = cached
            } else {
                pill = findNowPlayingBarPill(in: target.view)
            }
            if let pill {
                applyLiquidGlass(toPill: pill)
            }
        }
    }
}
