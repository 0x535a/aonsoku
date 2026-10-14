import UIKit

// A standalone Simulator harness: does not load Aonsoku, authenticate or create audio.
@main
final class ShellQAApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "QA", sessionRole: session.role)
        configuration.delegateClass = ShellQAScene.self
        return configuration
    }
}

final class ShellQAScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = ShellQAController()
        window?.makeKeyAndVisible()
    }
}

final class ShellQAController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.async { self.run() }
    }

    private func run() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shell = NativeBottomShellView()
        view.backgroundColor = .systemBackground
        view.addSubview(shell)
        var measurements: (CGFloat, CGFloat, Bool) = (0, 0, true)
        var events: [[String: Any]] = []
        shell.onInsetsChanged = { measurements = ($0, $1, $2) }
        shell.onEvent = { events.append($0) }
        let state: [String: Any] = [
            "enabled": true, "hasContent": true, "trackId": "fixture",
            "canOpenPlayer": true, "title": "Aonsoku · Native player", "artist": "QA fixture · no audio",
            "isPlaying": true, "hasNext": true, "activeIndex": 1,
            "labels": ["Home", "Library", "Search"], "playLabel": "Play", "pauseLabel": "Pause",
            "nextLabel": "Next", "openPlayerLabel": "Open player", "backLabel": "Back",
            "trackLabel": "Aonsoku, QA fixture", "progressFraction": 0.4,
        ]
        let configurations: [(String, CGFloat, CGFloat, UIUserInterfaceIdiom)] = [
            ("iphone-portrait", 390, 844, .phone),
            ("iphone-landscape", 844, 390, .phone),
            ("ipad-portrait", 834, 1194, .pad),
            ("ipad-landscape", 1194, 834, .pad),
            ("ipad-narrow-window", 600, 900, .pad),
        ]
        var results: [[String: Any]] = []
        for (name, width, height, idiom) in configurations {
            if #available(iOS 17.0, *) { shell.traitOverrides.userInterfaceIdiom = idiom }
            shell.frame = CGRect(x: 0, y: 0, width: width, height: height)
            shell.update(state)
            shell.layoutIfNeeded()
            let compact = idiom == .phone || width < 768
            precondition(measurements.2 == compact, "Incorrect adaptive layout: \(name)")
            precondition(measurements.0 == 0, "Native navigation must not reserve the top header")
            if !compact {
                precondition(shell.hitTest(CGPoint(x: width / 2, y: 90), with: nil) == nil,
                    "Wide windows must leave the Web navigation interactive")
            }
            precondition(measurements.1 >= 68, "Missing player reservation")
            let renderer = UIGraphicsImageRenderer(size: shell.bounds.size)
            let image = renderer.image { _ in
                UIColor.systemBackground.setFill()
                UIRectFill(shell.bounds)
                shell.drawHierarchy(in: shell.bounds, afterScreenUpdates: true)
            }
            try! image.pngData()!.write(to: directory.appendingPathComponent("\(name).png"))
            results.append(["case": name, "top": measurements.0, "bottom": measurements.1, "compact": compact])
        }
        var empty = state
        empty["hasContent"] = false
        shell.update(empty); shell.layoutIfNeeded()
        let emptyBottom = measurements.1
        shell.update(state); shell.layoutIfNeeded()
        precondition(emptyBottom < measurements.1, "Empty player must release its space")
        let children = descendants(shell)
        let pause = children.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Pause" }!
        pause.sendActions(for: .touchUpInside)
        precondition(events.last?["action"] as? String == "togglePlayPause")
        let next = children.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Next" }!
        next.sendActions(for: .touchUpInside)
        precondition(events.last?["action"] as? String == "playNextSong")
        shell.obscured = true; shell.layoutIfNeeded()
        precondition(shell.hitTest(CGPoint(x: 20, y: shell.bounds.height - 60), with: nil) == nil)
        shell.obscured = false; shell.keyboardVisible = true; shell.layoutIfNeeded()
        precondition(shell.hitTest(CGPoint(x: 20, y: shell.bounds.height - 60), with: nil) == nil)
        let data = try! JSONSerialization.data(withJSONObject: ["layouts": results, "controls": "passed", "empty": "passed", "modalAndKeyboard": "passed"], options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: directory.appendingPathComponent("results.json"))
        print("NATIVE_SHELL_QA_PASSED")
        fflush(stdout)
        exit(0)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
