import CarPlay
import UIKit

/// CarPlay scene delegate for Lara.
///
/// CarPlay does NOT support arbitrary screen mirroring. Third-party apps only
/// get template UI (lists, grids, alerts, map/nav templates) on the head unit,
/// gated by `CPTemplateApplicationScene` + Apple-approved entitlements
/// (`com.apple.developer.carplay-*`).
///
/// This delegate exposes Lara's exploit/toolbox *status* and a few safe
/// actions as a `CPListTemplate`. Dangerous actions (Run Exploit, Respring)
/// are gated behind a confirmation alert and should only be used while parked.
final class LaraCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        let root = LaraCarPlayManager.makeRootTemplate { [weak self] template, animated in
            self?.interfaceController?.setRootTemplate(template, animated: animated)
        }
        interfaceController.setRootTemplate(root, animated: false)
    }

    func templateApplicationSceneDidDisconnect(
        _ templateApplicationScene: CPTemplateApplicationScene
    ) {
        interfaceController = nil
    }
}

extension LaraCarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateWillAppear(_ template: CPTemplate, animated: Bool) {}
    func templateWillDisappear(_ template: CPTemplate, animated: Bool) {}
    func templateDidAppear(_ template: CPTemplate, animated: Bool) {}
    func templateDidDisappear(_ template: CPTemplate, animated: Bool) {}
}
