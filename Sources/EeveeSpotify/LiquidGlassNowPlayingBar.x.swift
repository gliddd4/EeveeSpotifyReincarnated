import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0
private var liquidGlassDiagnosticsKey = 0
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
    var candidates: [(String, String, Int)] = []
    var candidatesLogged = false

    func walk(_ view: UIView, depth: Int) {
        let frame = view.frame
        // The pill is nested (frame is in its superview's coordinates), so the
        // bottom-of-screen check must use window coordinates, not view.frame.
        let windowFrame = view.convert(view.bounds, to: nil)
        let isPillShape = frame.height >= 48 && frame.height <= 64
            && frame.width >= screen.width - 24 && frame.width <= screen.width + 2
            && windowFrame.maxY >= screen.height * 0.75 && windowFrame.maxY <= screen.height + 8
        // An opaque background (album-art fill) separates the pill from the
        // transparent outline/glow view that surrounds it.
        let hasFill = (view.backgroundColor?.cgColor.alpha ?? 0) > 0
        let score = (isPillShape ? 1 : 0) + (view.layer.cornerRadius > 0 ? 1 : 0) + (hasFill ? 1 : 0)

        if score > 0 {
            if !candidatesLogged {
                candidates.append((NSStringFromClass(type(of: view)), "\(frame)", score))
            }
            if score > bestScore || (score == bestScore && depth > bestDepth) {
                best = view
                bestScore = score
                bestDepth = depth
            }
        }
        for sub in view.subviews {
            walk(sub, depth: depth + 1)
        }
    }

    walk(root, depth: 0)
    if !candidates.isEmpty {
        for (name, frame, score) in candidates {
            writeDebugLog("[LiquidGlassNPB] Candidate: \(name) frame=\(frame) score=\(score)")
        }
        candidatesLogged = true
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

    if objc_getAssociatedObject(pill, &liquidGlassDiagnosticsKey) == nil {
        writeDebugLog("[LiquidGlassNPB] Pill subviews:")
        for sub in pill.subviews {
            writeDebugLog("[LiquidGlassNPB]   sub: \(NSStringFromClass(type(of: sub))) frame=\(sub.frame) cornerRadius=\(sub.layer.cornerRadius) bg=\(String(describing: sub.backgroundColor)) hidden=\(sub.isHidden)")
        }
        objc_setAssociatedObject(pill, &liquidGlassDiagnosticsKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

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

    // Neutralize opaque fills: the pill's own background, all plain UIView
    // containers, and any view (any class) that covers the full pill — the
    // tinted fill is a plain UIView here, but a full-size subclass would have
    // been missed by a class-name-only check. Content views (artwork, labels,
    // buttons) are smaller than 85% of the pill and are left alone.
    func clearFill(_ view: UIView) {
        let covers = view.bounds.width >= pillBounds.width * 0.85
            && view.bounds.height >= pillBounds.height * 0.85
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
    clearFill(pill)
    pill.backgroundColor = .clear
    pill.layer.backgroundColor = nil

    guard objc_getAssociatedObject(pill, &liquidGlassAppliedKey) == nil else { return }

    // iOS 26 shape + material. The light tint and hairline border keep the
    // glass readable even where Spotify's backdrop is flat black.
    pill.cornerConfiguration = .capsule()

    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = true
    glassEffect.tintColor = UIColor.white.withAlphaComponent(0.12)
    let glass = UIVisualEffectView(effect: glassEffect)
    glass.cornerConfiguration = .capsule()
    glass.isUserInteractionEnabled = false
    glass.isAccessibilityElement = false
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.layer.borderWidth = 0.5
    glass.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor

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
}

class NowPlayingBarViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LiquidGlassNowPlayingBarGroup
    static var targetName = "NowPlaying_BarImpl.NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()

        if #available(iOS 26.0, *) {
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
