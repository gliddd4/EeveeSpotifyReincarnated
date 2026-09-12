import Orion
import UIKit

// TRIAGE-ONLY gray-card probe (canvas-lyrics-triage): find out who paints the
// NP lyric card gray even though the delivered color-lyrics payload carries
// vibrant colors (probe showed bg=FFEC0000). Hooks every UIView's
// setBackgroundColor but only logs for Lyrics card views, then calls through.
class CardColorProbeHook: ClassHook<UIView> {
    typealias Group = V91LyricsGroup

    static var targetName: String { "UIView" }

    func setBackgroundColor(_ color: UIColor?) {
        let cls = NSStringFromClass(type(of: self))
        if cls.contains("Lyrics"), cls.contains("Card") {
            let stack = Thread.callStackSymbols
                .filter { $0.contains("Spotify") || $0.contains("EeveeSpotify") }
                .prefix(6)
                .joined(separator: " | ")
            writeDebugLog("[Lyrics] CardView paint \(cls) bg=\(String(describing: color)) stack=\(stack)")
        }
        orig.setBackgroundColor(color)
    }
}
