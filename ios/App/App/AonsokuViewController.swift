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
        #if DEBUG
        if ProcessInfo.processInfo.environment["AONSOKU_SHELL_BRIDGE_QA"] == "1" {
            startNativeShellBridgeQA()
        }
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let config = super.webViewConfiguration(for: instanceConfiguration)
        config.setURLSchemeHandler(mediaSchemeHandler, forURLScheme: "aonsoku-media")
        return config
    }

    // Capacitor replaces configuration.userContentController after calling
    // webViewConfiguration. Register on the final controller at the factory hook.
    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.userContentController.add(shellMessageHandler, name: "aonsokuShell")
        return super.webView(with: frame, configuration: configuration)
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
            #if DEBUG
            self.checkNativeShellBridgeQA(payload)
            #endif
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

    #if DEBUG
    private var shellQAStarted = false
    private var shellQAAttempts = 0

    private func startNativeShellBridgeQA() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.shellQAStarted else { return }
            self.shellQAAttempts += 1
            guard self.shellQAAttempts <= 80 else {
                print("NATIVE_SHELL_BRIDGE_QA_FAILED: WKWebView did not become ready")
                fflush(stdout)
                return
            }
            guard let webView = self.webView, !webView.isLoading, webView.url?.host == "localhost" else {
                self.startNativeShellBridgeQA()
                return
            }
            self.shellQAStarted = true
            webView.evaluateJavaScript("""
                (() => {
                const root = document.getElementById('root');
                if (!root?.querySelector('[data-native-web-player], input')) return false;
                if (!window.webkit?.messageHandlers?.aonsokuShell) {
                    throw new Error('Final WKUserContentController has no shell handler');
                }
                window.addEventListener('aonsoku-native-shell', event => {
                    if (event.detail.type === 'layout') {
                        window.__shellQALayout = event.detail;
                    }
                });
                window.webkit.messageHandlers.aonsokuShell.postMessage({
                    type: 'state', enabled: true, hasContent: true, canOpenPlayer: true,
                    trackId: 'bridge-qa', title: 'Capacitor bridge QA', artist: 'No audio fixture',
                    labels: ['Home', 'Library', 'Search'], isPlaying: true, hasNext: true,
                    activeIndex: 1, __bridgeQA: true
                });
                return true;
                })()
                """) { result, error in
                    if let error {
                        print("NATIVE_SHELL_BRIDGE_QA_FAILED: \(error.localizedDescription)")
                        fflush(stdout)
                    } else if result as? Bool != true {
                        self.shellQAStarted = false
                        self.startNativeShellBridgeQA()
                    }
                }
        }
    }

    private func checkNativeShellBridgeQA(_ state: [String: Any]) {
        guard ProcessInfo.processInfo.environment["AONSOKU_SHELL_BRIDGE_QA"] == "1",
              state["__bridgeQA"] as? Bool == true else { return }
        precondition(nativeShell.enabled, "Real WK message did not enable native controls")
        // Layout travels back asynchronously over WK evaluateJavaScript.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.webView?.evaluateJavaScript("""
                (() => {
                    const nav = document.querySelector('[data-native-web-bottom-nav]');
                    const player = document.querySelector('[data-native-web-player]');
                    return {
                        layout: window.__shellQALayout,
                        reactMounted: Boolean(nav && player),
                        webChromeHidden: !nav || !player || (
                            getComputedStyle(nav).display === 'none' &&
                            getComputedStyle(player).display === 'none'
                        )
                    };
                })()
                """) { result, error in
                guard error == nil, let snapshot = result as? [String: Any],
                      let layout = snapshot["layout"] as? [String: Any],
                      let bottom = layout["bottom"] as? Double, bottom > 0,
                      snapshot["webChromeHidden"] as? Bool == true else {
                    print("NATIVE_SHELL_BRIDGE_QA_FAILED: measured layout did not reach WebView")
                    fflush(stdout)
                    return
                }
                let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("native-shell-bridge-qa.json")
                let data = try? JSONSerialization.data(withJSONObject: [
                    "realCapacitorHandler": "passed", "nativeStateReceived": "passed",
                    "layoutRoundTrip": "passed", "layout": layout,
                    "reactMounted": snapshot["reactMounted"] ?? false,
                    "webChromeHidden": snapshot["webChromeHidden"] ?? false
                ], options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: output)
                print("NATIVE_SHELL_BRIDGE_QA_PASSED")
                fflush(stdout)
            }
        }
    }
    #endif

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
              let url = message.frameInfo.request.url,
              ["capacitor", "https"].contains(url.scheme ?? ""),
              url.host == "localhost" else { return }
        viewController?.receiveShellMessage(message.body)
    }
}
