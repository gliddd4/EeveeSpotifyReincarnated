import Orion
import UIKit
import ObjectiveC.runtime

private let playerLock = NSLock()
private var _statefulPlayer: StatefulPlayerImplementation?
private var _backgroundViewModel: SPTNowPlayingBackgroundViewModel?

var statefulPlayer: StatefulPlayerImplementation? {
    get { playerLock.lock(); defer { playerLock.unlock() }; return _statefulPlayer }
    set { playerLock.lock(); _statefulPlayer = newValue; playerLock.unlock() }
}

var backgroundViewModel: SPTNowPlayingBackgroundViewModel? {
    get { playerLock.lock(); defer { playerLock.unlock() }; return _backgroundViewModel }
    set { playerLock.lock(); _backgroundViewModel = newValue; playerLock.unlock() }
}

var scrollDataSource: NowPlayingScrollDataSourceImplementation?

var nowPlayingScrollViewController: NowPlayingScrollViewController?
var npvScrollViewController: NPVScrollViewController?

class LegacyNowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = IOS14PremiumPatchingGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayer() -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayer()
        return statefulPlayer!
    }
}

class NowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = NonIOS14PremiumPatchingGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayerWithFeatureIdentifier(_ identifier: NSString) -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayerWithFeatureIdentifier(identifier)
        return statefulPlayer!
    }
}

class NowPlayingScrollPrivateServiceImplementationHook: ClassHook<NSObject> {
    typealias Group = BaseLyricsGroup
    static let targetName = "NowPlaying_ScrollImpl.NowPlayingScrollPrivateServiceImplementation"
    
    static func hookWillActivate() -> Bool {
        guard let cls = NSClassFromString(Self.targetName),
              class_getInstanceMethod(cls, Selector(("provideScrollViewControllerWithDependencies:"))) != nil else {
            return false
        }
        return true
    }
    
    func provideScrollViewControllerWithDependencies(_ dependencies: NSObject) -> UIViewController {
        let scrollViewController = orig.provideScrollViewControllerWithDependencies(dependencies)
        
        if NSStringFromClass(type(of: scrollViewController)) ~= "NowPlayingScrollViewController" {
            nowPlayingScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NowPlayingScrollViewController.self
            )
        }
        else {
            scrollDataSource = Ivars<NowPlayingScrollDataSourceImplementation>(target)
                .$__lazy_storage_$_scrollDataSource
            npvScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NPVScrollViewController.self
            )
        }
        
        backgroundViewModel = Ivars<SPTNowPlayingBackgroundViewModel>(dependencies)
            .backgroundViewModel
        
        return scrollViewController
    }
}
