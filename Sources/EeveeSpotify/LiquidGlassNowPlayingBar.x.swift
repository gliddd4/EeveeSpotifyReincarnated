import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0
private var liquidGlassBackdropKey = 0
private var liquidGlassStateKey = 0
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
        // transparent outline/glow view that surrounds it.
        let hasFill = (view.backgroundColor?.cgColor.alpha ?? 0) > 0
        let score = (view.layer.cornerRadius > 0 ? 1 : 0) + (hasFill ? 1 : 0)

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

    // Spotify paints the pill's gray tint onto its own background AFTER our
    // scan (shouldUpdateTopContainerColor), so the glass cannot rely on that
    // layer being sampled. A backdrop subview sits directly below the glass
    // and mirrors the pill's background on every layout pass — the glass
    // always has the tint behind it, whenever Spotify sets it.
    if let backdrop = objc_getAssociatedObject(pill, &liquidGlassBackdropKey) as? UIView {
        backdrop.backgroundColor = pill.backgroundColor
    } else if objc_getAssociatedObject(pill, &liquidGlassAppliedKey) == nil {
        let backdrop = UIView(frame: pillBounds)
        backdrop.isUserInteractionEnabled = false
        backdrop.isAccessibilityElement = false
        backdrop.layer.cornerRadius = pill.layer.cornerRadius
        backdrop.layer.masksToBounds = true
        backdrop.backgroundColor = pill.backgroundColor
        pill.insertSubview(backdrop, at: 0)

        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        glassEffect.tintColor = UIColor.white.withAlphaComponent(0.12)
        let glass = UIVisualEffectView(effect: glassEffect)
        glass.isUserInteractionEnabled = false
        glass.isAccessibilityElement = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.borderWidth = 0.5
        glass.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor

        // Match the pill's own nearly-rectangular radius; a full capsule would
        // crop the album art.
        let radius = max(pill.layer.cornerRadius, 1)
        pill.cornerConfiguration = .continuous(radius)
        glass.cornerConfiguration = .continuous(radius)

        pill.insertSubview(glass, at: 1)
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

    // Timeline of the pill's appearance for debugging: logged only when it
    // changes, so the next export shows when Spotify paints the tint.
    let state = "subviews=\(pill.subviews.count) bg=\(String(describing: pill.backgroundColor))"
    let last = objc_getAssociatedObject(pill, &liquidGlassStateKey) as? String
    if last != state {
        writeDebugLog("[LiquidGlassNPB] Pill state: \(state)")
    }
    objc_setAssociatedObject(pill, &liquidGlassStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
