import UIKit
import Capacitor
import WebKit
import AonsokuNativePlugin

class AonsokuViewController: CAPBridgeViewController {
    private let mediaSchemeHandler = MediaSchemeHandler()
    private let shellMessageHandler = NativeShellMessageHandler()
    private let startupBackgroundColor = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 6 / 255, green: 14 / 255, blue: 35 / 255, alpha: 1)
        }
        return UIColor(red: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = startupBackgroundColor
        webView?.backgroundColor = startupBackgroundColor
        webView?.scrollView.backgroundColor = startupBackgroundColor
        webView?.allowsBackForwardNavigationGestures = true
        shellMessageHandler.viewController = self
        installNativeShell()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let config = super.webViewConfiguration(for: instanceConfiguration)
        config.setURLSchemeHandler(mediaSchemeHandler, forURLScheme: "aonsoku-media")
        config.userContentController.add(shellMessageHandler, name: "aonsokuShell")
        return config
    }

    private let nativeShell = NativeBottomShellView()

    private func installNativeShell() {
        nativeShell.frame = view.bounds
        nativeShell.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nativeShell.onEvent = { [weak self] in self?.sendShellEvent($0) }
        nativeShell.onInsetsChanged = { [weak self] top, bottom, compact in
            self?.sendShellEvent(["type": "layout", "top": top, "bottom": bottom, "compact": compact])
        }
        view.addSubview(nativeShell)
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = view.window else { return }
        let localFrame = view.convert(frame, from: window.screen.coordinateSpace)
        let intersection = view.bounds.intersection(localFrame)
        // Floating iPad keyboards do not cover the bottom controls.
        nativeShell.keyboardVisible = !intersection.isNull && intersection.height > 40
            && intersection.maxY >= view.bounds.maxY - 2
    }

    @objc private func keyboardHidden(_ notification: Notification) {
        nativeShell.keyboardVisible = false
    }

    override var keyCommands: [UIKeyCommand]? {
        ["1", "2", "3"].map {
            UIKeyCommand(input: $0, modifierFlags: .command, action: #selector(selectTabFromKeyboard))
        }
    }

    @objc private func selectTabFromKeyboard(_ command: UIKeyCommand) {
        guard nativeShell.enabled, !nativeShell.obscured,
              let input = command.input, let index = Int(input) else { return }
        sendShellEvent(["type": "tab", "index": index - 1])
    }

    func receiveShellMessage(_ body: Any) {
        guard let payload = body as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch payload["type"] as? String {
            case "state": nativeShell.update(payload)
            case "artwork": nativeShell.updateArtwork(payload)
            case "visibility": nativeShell.obscured = payload["obscured"] as? Bool ?? false
            default: return
            }
            if let dark = payload["dark"] as? Bool {
                nativeShell.overrideUserInterfaceStyle = dark ? .dark : .light
            }
            nativeShell.layoutIfNeeded()
        }
    }

    private func sendShellEvent(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('aonsoku-native-shell', {detail: \(json)}))"
        )
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            presentDebugMenu()
        }
    }

    private func presentDebugMenu() {
        guard presentedViewController == nil else { return }
        let debugVC = DebugViewController(bridge: bridge)
        let nav = UINavigationController(rootViewController: debugVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}

private final class NativeShellMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: AonsokuViewController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              ["capacitor", "https"].contains(message.frameInfo.securityOrigin.protocol),
              message.frameInfo.securityOrigin.host == "localhost" else { return }
        viewController?.receiveShellMessage(message.body)
    }
}
