import UIKit

// Standalone UIKit accessory fixture. It never starts audio or loads the app.
@main
final class ShellQAApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "QA", sessionRole: session.role)
        if #available(iOS 26.0, *) { configuration.delegateClass = ShellQAScene.self }
        return configuration
    }
}

@available(iOS 26.0, *)
final class ShellQAScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = ShellQAController()
        window?.makeKeyAndVisible()
    }
}

@available(iOS 26.0, *)
final class ShellQAController: UITabBarController, UITabBarControllerDelegate {
    private let shell = NativeBottomShellView()
    private var events: [[String: Any]] = []
    private var didRun = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        mode = .tabSidebar
        tabs = [
            UITab(title: "Home", image: UIImage(systemName: "house"), identifier: "home") { _ in UIViewController() },
            UITab(title: "Library", image: UIImage(systemName: "books.vertical"), identifier: "library") { _ in UIViewController() },
            UITab(title: "Search", image: UIImage(systemName: "magnifyingglass"), identifier: "search") { _ in UIViewController() },
        ]
        bottomAccessory = UITabAccessory(contentView: shell)
        shell.onEvent = { [weak self] in self?.events.append($0) }
        shell.update([
            "enabled": true, "hasContent": true, "trackId": "fixture",
            "canOpenPlayer": true, "title": "Aonsoku", "artist": "No audio fixture",
            "isPlaying": true, "hasNext": true, "activeIndex": 1,
            "playLabel": "Play", "pauseLabel": "Pause", "nextLabel": "Next",
            "openPlayerLabel": "Open player", "trackLabel": "Aonsoku QA",
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didRun else { return }
        didRun = true
        DispatchQueue.main.async { self.run() }
    }

    private func run() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        shell.traitOverrides.tabAccessoryEnvironment = .regular
        shell.setNeedsLayout()
        shell.layoutIfNeeded()
        precondition(!shell.accessoryPresentation.inline, "Regular accessory should show full controls")
        precondition(shell.accessoryPresentation.artistVisible && shell.accessoryPresentation.nextVisible)
        precondition(shell.intrinsicContentSize.height == 64)
        let pause = shell.controlButtons.first { $0.accessibilityLabel == "Pause" }!
        pause.sendActions(for: .touchUpInside)
        precondition(events.last?["action"] as? String == "togglePlayPause")
        let next = shell.controlButtons.first { $0.accessibilityLabel == "Next" }!
        next.sendActions(for: .touchUpInside)
        precondition(events.last?["action"] as? String == "playNextSong")

        shell.traitOverrides.tabAccessoryEnvironment = .inline
        shell.setNeedsLayout()
        shell.layoutIfNeeded()
        precondition(shell.accessoryPresentation.inline, "Collapsed accessory should adopt inline controls")
        precondition(!shell.accessoryPresentation.artistVisible && !shell.accessoryPresentation.nextVisible)
        precondition(shell.intrinsicContentSize.height == 44)

        shell.traitOverrides.tabAccessoryEnvironment = .regular
        shell.setNeedsLayout()
        shell.layoutIfNeeded()
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        try! image.pngData()!.write(to: directory.appendingPathComponent("accessory-regular.png"))

        shell.obscured = true
        precondition(shell.isHidden, "Fullscreen/modal should suspend the accessory")
        shell.obscured = false
        shell.keyboardVisible = true
        precondition(shell.isHidden, "Docked keyboard should suspend the accessory")

        let data = try! JSONSerialization.data(withJSONObject: [
            "systemTabController": "passed", "systemAccessory": "passed",
            "regularEnvironment": "passed", "inlineEnvironment": "passed",
            "controls": "passed", "modalAndKeyboard": "passed",
        ], options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: directory.appendingPathComponent("results.json"))
        print("NATIVE_SHELL_QA_PASSED")
        fflush(stdout)
        exit(0)
    }

}
