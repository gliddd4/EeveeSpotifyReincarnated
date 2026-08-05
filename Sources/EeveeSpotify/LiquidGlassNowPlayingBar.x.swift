import Orion
import UIKit

// Forces Spotify's custom now playing bar (mini player) to render with the
// system Liquid Glass material. Only supported on iOS 26+ — the UIGlassEffect
// APIs do not exist before that, so everything below is gated on iOS 26.
struct LiquidGlassNowPlayingBarGroup: HookGroup { }

private var liquidGlassAppliedKey = 0

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

// Locates the floating pill (NowPlaying_BarImpl.NowPlayingBarView). Falls back
// to a frame heuristic (56pt tall, ~8pt horizontal inset) so it survives the
// Swift-mangled class name changing between Spotify builds.
private func findNowPlayingBarPill(in root: UIView) -> UIView? {
    var best: UIView?
    let screenWidth = UIScreen.main.bounds.width

    func walk(_ view: UIView) {
        let name = NSStringFromClass(type(of: view))
        let inset = view.frame.minX
        let isInsetPill = view.bounds.height >= 48 && view.bounds.height <= 64
            && inset >= 4 && inset <= 16
            && view.frame.width >= screenWidth - 24

        if name.contains("NowPlayingBarView") || isInsetPill {
            let area = view.bounds.width * view.bounds.height
            if best == nil || area > best!.bounds.width * best!.bounds.height {
                best = view
            }
        }
        for sub in view.subviews {
            walk(sub)
        }
    }

    walk(root)
    return best
}

@available(iOS 26.0, *)
private func applyLiquidGlass(toPill pill: UIView) {
    if objc_getAssociatedObject(pill, &liquidGlassAppliedKey) != nil {
        return
    }
    objc_setAssociatedObject(pill, &liquidGlassAppliedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    // Spotify draws its border/shadow/glow on a view expanded ~4pt beyond the
    // pill. Hide it so the Liquid Glass material owns the edge.
    for sub in pill.subviews
        where sub.frame.minX < -0.5 || sub.frame.minY < -0.5
            || sub.frame.width > pill.bounds.width + 0.5
            || sub.frame.height > pill.bounds.height + 0.5 {
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
}

class NowPlayingBarViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LiquidGlassNowPlayingBarGroup
    static var targetName = "NowPlaying_BarImpl.NowPlayingBarViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()

        if #available(iOS 26.0, *),
           let pill = findNowPlayingBarPill(in: target.view) {
            applyLiquidGlass(toPill: pill)
        }
    }
}
