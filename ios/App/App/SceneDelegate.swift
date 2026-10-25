import UIKit
import Capacitor
import AonsokuNativePlugin

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Multiple scene roles allow CarPlay alongside the phone. Keep one phone
        // WebView even when iPadOS requests another application window.
        if let existing = UIApplication.shared.connectedScenes.first(where: {
            $0 !== scene && $0.session.role == .windowApplication
                && ($0.delegate as? SceneDelegate)?.window != nil
        }) {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            UIApplication.shared.requestSceneSessionActivation(existing.session, userActivity: nil, options: nil)
            return
        }

        window = UIWindow(windowScene: windowScene)
        #if DEBUG
        if CarPlayQA.enabled {
            window?.rootViewController = UIViewController()
            window?.makeKeyAndVisible()
            return
        }
        #endif
        if #available(iOS 26.0, *) {
            window?.rootViewController = AonsokuNativeTabController()
        } else {
            // Older systems retain the shared Web navigation and player chrome.
            window?.rootViewController = AonsokuViewController()
        }
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
