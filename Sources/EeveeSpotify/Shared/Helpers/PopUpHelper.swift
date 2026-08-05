import UIKit
import Orion

struct PopUpHelper {
    private static var isPopUpShowing = false
    
    static let sharedPresenter = type(
        of: Dynamic.SPTEncorePopUpPresenter
        .alloc(interface: SPTEncorePopUpPresenter.self)
    )
    .shared()

    static func showPopUp(
        delayed: Bool = false,
        message: String,
        buttonText: String,
        secondButtonText: String? = nil,
        onPrimaryClick: (() -> Void)? = nil,
        onSecondaryClick: (() -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: delayed ? .now() + 3.0 : .now()) {
            if isPopUpShowing {
                return
            }

            isPopUpShowing = true

            let model = Dynamic.SPTEncorePopUpDialogModel
                .alloc(interface: SPTEncorePopUpDialogModel.self)
                .initWithTitle(
                    "EeveeSpotify",
                    description: message,
                    image: nil,
                    primaryButtonTitle: buttonText,
                    secondaryButtonTitle: secondButtonText
                )

            let dialog = Dynamic.SPTEncorePopUpDialog
                .alloc(interface: SPTEncorePopUpDialog.self)
                .`init`()
            
            dialog.update(model)
            dialog.setEventHandler({ state in
                switch (state) {
                
                case .primary: onPrimaryClick?()
                case .secondary: onSecondaryClick?()

                }

                sharedPresenter.dismissPopupWithAnimate(true, clearQueue: false, completion: nil)
                isPopUpShowing = false
            })

            sharedPresenter.presentPopUp(dialog)
        }
    }

    /// Releases the "a popup is up" latch. Called from the popup's event handler
    /// and from the SPTEncorePopUpPresenter dismiss hook, so every dismissal path
    /// (button click, outside-tap, Spotify-initiated dismiss) clears the latch —
    /// without this, a popup dismissed outside its event handler leaves the latch
    /// set forever and silently drops every later popup.
    static func resetIsPopUpShowing() {
        isPopUpShowing = false
    }
}
