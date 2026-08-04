import Orion
import UIKit

// ErrorViewController doesn't exist in Spotify 9.1.x - separate group to avoid crashes
class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    
    static var targetName: String {
        if EeveeSpotify.hookTarget == .v91 {
            return "UIView" // ErrorViewController doesn't exist on 9.1.x
        }
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
            
            guard Dynamic.convert(controller, to: NSObject.self).responds(to: Selector("collectionView")) else {
                return
            }
            let collectionView = controller.collectionView()
            let dataSource = Ivars<__UIDiffableDataSource>(collectionView.dataSource!)._impl
            
            let itemIdentifiers = dataSource.itemIdentifiers()
            let lyricsProviderItemIdentifier = itemIdentifiers[lyricsProviderIndex!]
            
            dataSource.deleteItemsWithIdentifiers([lyricsProviderItemIdentifier])
        }
    }
}
