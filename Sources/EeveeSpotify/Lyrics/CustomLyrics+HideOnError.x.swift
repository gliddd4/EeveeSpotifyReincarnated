import Orion
import UIKit

// ErrorViewController doesn't exist in Spotify 9.1.x - separate group to avoid crashes
class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    
    static var targetName: String {
        // ── START OF AI GENERATED CODE ──
        if EeveeSpotify.hookTarget == .v91 {
            return "UIView" // ErrorViewController doesn't exist on 9.1.x
        }
        // ── END OF AI GENERATED CODE ──
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.ErrorViewController"
        default: return "Lyrics_NPVCommunicatorImpl.ErrorViewController"
        }
    }
    
    func loadView() {
        orig.loadView()
        
        guard UserDefaults.lyricsOptions.hideOnError else {
            return
        }
        
        if let controller = nowPlayingScrollViewController {
            controller.dataSource.activeProviders.removeAll {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            controller.collectionView().reloadData()
        }
        else if let controller = npvScrollViewController, let dataSource = scrollDataSource {
            let lyricsProviderIndex = dataSource.activeProviders.firstIndex {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            // ── START OF AI GENERATED CODE ──
            guard Dynamic.convert(controller, to: NSObject.self).responds(to: Selector("collectionView")) else {
                return
            }
            // ── END OF AI GENERATED CODE ──
            let collectionView = controller.collectionView()
            guard let collectionViewDataSource = collectionView.dataSource else {
                return
            }
            let dataSource = Ivars<__UIDiffableDataSource>(collectionViewDataSource)._impl
            
            let itemIdentifiers = dataSource.itemIdentifiers()
            guard let lyricsProviderIndex,
                  lyricsProviderIndex < itemIdentifiers.count else {
                return
            }
            let lyricsProviderItemIdentifier = itemIdentifiers[lyricsProviderIndex]
            
            dataSource.deleteItemsWithIdentifiers([lyricsProviderItemIdentifier])
        }
    }
}
